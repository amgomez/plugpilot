#ifndef PLUGPILOT_SHIM_H
#define PLUGPILOT_SHIM_H

#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/IOKitLib.h>

// Undocumented calls used internally by System Settings and by the widely-used
// `blueutil` tool. There is no public API to toggle Bluetooth power.
extern int IOBluetoothPreferenceGetControllerPowerState(void);
extern void IOBluetoothPreferenceSetControllerPowerState(int state);

// Reads a temperature sensor from the SMC (System Management Controller) given its
// 4-character key (e.g. "TC0P"). Returns -1.0 if the key doesn't exist or can't be read.
// This talks to the AppleSMC IOKit user client using its reverse-engineered protocol —
// there is no public Apple API for SMC sensors.
double SMCGetTemperature(const char *key);

// Reads an SMC key stored as a 32-bit float (used for fan RPM values, e.g. "F0Ac").
double SMCGetFloatValue(const char *key);

// Puts a fan in forced (1) or automatic (0) mode by writing F#Md. On recent Intel
// firmwares the fan minimum key (F#Mn) is read-only and this is the only control path.
int SMCWriteFanMode(int fanIndex, int forced);

// Writes the target RPM for a fan (F#Tg). Only takes effect while forced mode is on.
int SMCWriteFanTargetRPM(int fanIndex, float rpm);

// Number of fans reported by the SMC ("FNum").
int SMCGetFanCount(void);

#endif
