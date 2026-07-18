#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "shim.h"

// Daemon root mínimo para PlugPilot. El SMC solo acepta escrituras desde
// root, así que la app le pide por XPC los ajustes de ventilador. En muchos firmwares
// Intel el mínimo (F#Mn) es de solo lectura: el control es modo forzado (F#Md=1) + RPM
// objetivo (F#Tg). La superficie es deliberadamente mínima: solo modo y objetivo, con
// las RPM acotadas en cada petición entre el mínimo de fábrica (F#Mn) y el máximo
// (F#Mx) que reporta el propio SMC de esta máquina — no hay tabla fija: cada Mac tiene
// sus propios mínimos/máximos. Forzar ventiladores más rápido que el mínimo de fábrica
// nunca es peligroso térmicamente; más lento sí podría serlo, así que si F#Mn o F#Mx no
// se pueden leer no se escribe nada.

#define SERVICE_NAME "com.amgg.plugpilot.helper"

// El helper se lanza bajo demanda (launchd, MachServices) y sale solo tras unos
// segundos sin peticiones, para no dejar un proceso root residente.
static int64_t generation = 0;

static void armIdleExit(void) {
    int64_t current = ++generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (generation == current) {
            exit(0);
        }
    });
}

static void handleRequest(xpc_object_t event) {
    int64_t fan = xpc_dictionary_get_int64(event, "fan");
    int64_t mode = xpc_dictionary_get_int64(event, "mode");
    double rpm = xpc_dictionary_get_double(event, "rpm");
    int64_t status = -1;

    if (fan >= 0 && fan < (int64_t)SMCGetFanCount()) {
        if (mode == 1) {
            char minKey[5];
            char maxKey[5];
            snprintf(minKey, sizeof(minKey), "F%dMn", (int)fan);
            snprintf(maxKey, sizeof(maxKey), "F%dMx", (int)fan);
            double factoryMin = SMCGetFloatValue(minKey);
            double factoryMax = SMCGetFloatValue(maxKey);

            if (factoryMin < 0 || factoryMax < 0) {
                // Nunca inventar un mínimo: forzar por debajo del mínimo de fábrica real
                // puede ser peligroso térmicamente, así que sin poder leerlo no se escribe.
                status = -3;
            } else {
                if (rpm < factoryMin) {
                    rpm = factoryMin;
                }
                if (rpm > factoryMax) {
                    rpm = factoryMax;
                }
                // Primero el modo y después el objetivo: en modo auto el SMC reescribe
                // F#Tg continuamente con su propia curva (sobre todo al cambiar la fuente
                // de alimentación), y pisaba nuestra escritura antes de que llegara el
                // forzado. Congelar primero es inocuo: el objetivo vigente es el que auto
                // ya aplicaba.
                status = SMCWriteFanMode((int)fan, 1);
                if (status == 0) {
                    status = SMCWriteFanTargetRPM((int)fan, (float)rpm);
                }
                if (status == 0) {
                    // Relectura de verificación con un reintento, por si quedaba una
                    // escritura del SMC en vuelo.
                    char key[5];
                    snprintf(key, sizeof(key), "F%dTg", (int)fan);
                    double applied = SMCGetFloatValue(key);
                    if (applied < rpm - 1.0 || applied > rpm + 1.0) {
                        status = SMCWriteFanTargetRPM((int)fan, (float)rpm);
                        if (status == 0) {
                            applied = SMCGetFloatValue(key);
                            if (applied < rpm - 1.0 || applied > rpm + 1.0) {
                                status = -2;
                            }
                        }
                    }
                }
            }
        } else if (mode == 0) {
            status = SMCWriteFanMode((int)fan, 0);
        }
    }

    xpc_object_t reply = xpc_dictionary_create_reply(event);
    if (reply != NULL) {
        xpc_dictionary_set_int64(reply, "status", status);
        xpc_connection_t remote = xpc_dictionary_get_remote_connection(event);
        if (remote != NULL) {
            xpc_connection_send_message(remote, reply);
        }
        xpc_release(reply);
    }
}

int main(void) {
    xpc_connection_t listener = xpc_connection_create_mach_service(
        SERVICE_NAME, dispatch_get_main_queue(), XPC_CONNECTION_MACH_SERVICE_LISTENER);

    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) {
            return;
        }
        xpc_connection_set_target_queue((xpc_connection_t)peer, dispatch_get_main_queue());
        xpc_connection_set_event_handler((xpc_connection_t)peer, ^(xpc_object_t event) {
            if (xpc_get_type(event) == XPC_TYPE_DICTIONARY) {
                armIdleExit();
                handleRequest(event);
            }
        });
        xpc_connection_activate((xpc_connection_t)peer);
    });

    xpc_connection_activate(listener);
    armIdleExit();
    dispatch_main();
}
