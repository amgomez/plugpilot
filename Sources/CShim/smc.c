#include "include/shim.h"
#include <mach/mach.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

typedef struct {
    unsigned char major;
    unsigned char minor;
    unsigned char build;
    unsigned char reserved;
    uint16_t release;
} SMCKeyData_vers_t;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    unsigned char dataAttributes;
} SMCKeyData_keyInfo_t;

typedef struct {
    uint32_t key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    unsigned char result;
    unsigned char status;
    unsigned char data8;
    uint32_t data32;
    unsigned char bytes[32];
} SMCKeyData_t;

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_KEYINFO 9
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6

#define SMC_BYTES_MAX 32

static uint32_t stringToKey(const char *str) {
    uint32_t key = 0;
    for (int i = 0; i < 4; i++) {
        key = (key << 8) + (uint32_t)str[i];
    }
    return key;
}

// Conexión única y perezosa al user client de AppleSMC. Abrir y cerrar el servicio en
// cada lectura era un desperdicio (abrir el menú dispara ~10 lecturas seguidas).
// Solo se llama desde el hilo principal, así que no necesita sincronización.
static io_connect_t smcConnection(void) {
    static io_connect_t conn = IO_OBJECT_NULL;
    if (conn != IO_OBJECT_NULL) {
        return conn;
    }
    io_service_t device = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (device == IO_OBJECT_NULL) {
        return IO_OBJECT_NULL;
    }
    kern_return_t kr = IOServiceOpen(device, mach_task_self(), 0, &conn);
    IOObjectRelease(device);
    if (kr != KERN_SUCCESS) {
        conn = IO_OBJECT_NULL;
    }
    return conn;
}

// Consulta tamaño y tipo de una clave. Devuelve 0 si la clave existe.
static int smcReadKeyInfo(io_connect_t conn, uint32_t key, SMCKeyData_keyInfo_t *outInfo) {
    SMCKeyData_t inputStruct;
    SMCKeyData_t outputStruct;
    size_t outputSize = sizeof(outputStruct);

    memset(&inputStruct, 0, sizeof(inputStruct));
    memset(&outputStruct, 0, sizeof(outputStruct));
    inputStruct.key = key;
    inputStruct.data8 = SMC_CMD_READ_KEYINFO;

    kern_return_t kr = IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, &inputStruct, sizeof(inputStruct), &outputStruct, &outputSize);
    if (kr != KERN_SUCCESS || outputStruct.keyInfo.dataSize == 0) {
        return -1;
    }
    *outInfo = outputStruct.keyInfo;
    return 0;
}

// Lee los bytes crudos de `keyString` en `outBytes` (debe tener SMC_BYTES_MAX bytes)
// y deja el tipo declarado por el SMC en `outDataType`. Devuelve los bytes leídos o -1.
static int smcReadRawBytes(const char *keyString, unsigned char *outBytes, uint32_t *outDataType) {
    io_connect_t conn = smcConnection();
    if (conn == IO_OBJECT_NULL) {
        return -1;
    }

    uint32_t key = stringToKey(keyString);
    SMCKeyData_keyInfo_t keyInfo;
    if (smcReadKeyInfo(conn, key, &keyInfo) != 0) {
        return -1;
    }

    SMCKeyData_t inputStruct;
    SMCKeyData_t outputStruct;
    size_t outputSize = sizeof(outputStruct);

    memset(&inputStruct, 0, sizeof(inputStruct));
    memset(&outputStruct, 0, sizeof(outputStruct));
    inputStruct.key = key;
    inputStruct.keyInfo.dataSize = keyInfo.dataSize;
    inputStruct.data8 = SMC_CMD_READ_BYTES;

    kern_return_t kr = IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, &inputStruct, sizeof(inputStruct), &outputStruct, &outputSize);
    if (kr != KERN_SUCCESS) {
        return -1;
    }

    // dataSize viene del kernel: nunca copiar más allá del búfer del llamador.
    uint32_t dataSize = keyInfo.dataSize;
    if (dataSize > SMC_BYTES_MAX) {
        dataSize = SMC_BYTES_MAX;
    }
    memcpy(outBytes, outputStruct.bytes, dataSize);
    if (outDataType) {
        *outDataType = keyInfo.dataType;
    }
    return (int)dataSize;
}

// Decodifica un valor numérico según el tipo que declara el propio SMC, en lugar de
// asumir un formato fijo: los sensores Intel usan sp78/fpe2, los Mac más recientes flt.
static double smcDecodeNumeric(uint32_t dataType, const unsigned char *bytes, int size) {
    if (dataType == stringToKey("flt ") && size >= 4) {
        float value;
        memcpy(&value, bytes, sizeof(value));
        return (double)value;
    }
    if (dataType == stringToKey("sp78") && size >= 2) {
        int16_t raw = (int16_t)(((uint16_t)bytes[0] << 8) | bytes[1]);
        return (double)raw / 256.0;
    }
    if (dataType == stringToKey("fpe2") && size >= 2) {
        uint16_t raw = (uint16_t)(((uint16_t)bytes[0] << 8) | bytes[1]);
        return (double)raw / 4.0;
    }
    if (dataType == stringToKey("ui8 ") && size >= 1) {
        return (double)bytes[0];
    }
    if (dataType == stringToKey("ui16") && size >= 2) {
        return (double)(((uint16_t)bytes[0] << 8) | bytes[1]);
    }
    if (dataType == stringToKey("ui32") && size >= 4) {
        return (double)(((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | bytes[3]);
    }
    return -1.0;
}

static double smcReadNumericValue(const char *keyString) {
    unsigned char bytes[SMC_BYTES_MAX];
    uint32_t dataType = 0;
    int size = smcReadRawBytes(keyString, bytes, &dataType);
    if (size < 0) {
        return -1.0;
    }
    return smcDecodeNumeric(dataType, bytes, size);
}

double SMCGetTemperature(const char *keyString) {
    return smcReadNumericValue(keyString);
}

double SMCGetFloatValue(const char *keyString) {
    return smcReadNumericValue(keyString);
}

// Bit de atributos que marca una clave como escribible. Comprobado empíricamente:
// F0Md/F0Tg lo tienen y F0Mn no — y el SMC *acepta sin error* (kr=éxito) escrituras a
// claves de solo lectura que luego descarta, así que hay que rechazarlas aquí.
#define SMC_ATTR_WRITABLE 0x40

static int smcWriteBytes(const char *keyString, uint32_t expectedType, const unsigned char *bytes, uint32_t size) {
    io_connect_t conn = smcConnection();
    if (conn == IO_OBJECT_NULL) {
        return -1;
    }

    uint32_t key = stringToKey(keyString);
    SMCKeyData_keyInfo_t keyInfo;
    if (smcReadKeyInfo(conn, key, &keyInfo) != 0) {
        return -1;
    }
    if (keyInfo.dataType != expectedType || keyInfo.dataSize != size ||
        !(keyInfo.dataAttributes & SMC_ATTR_WRITABLE)) {
        return -1;
    }

    SMCKeyData_t inputStruct;
    SMCKeyData_t outputStruct;
    size_t outputSize = sizeof(outputStruct);

    memset(&inputStruct, 0, sizeof(inputStruct));
    memset(&outputStruct, 0, sizeof(outputStruct));
    inputStruct.key = key;
    inputStruct.keyInfo.dataSize = size;
    inputStruct.data8 = SMC_CMD_WRITE_BYTES;
    memcpy(inputStruct.bytes, bytes, size);

    kern_return_t kr = IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, &inputStruct, sizeof(inputStruct), &outputStruct, &outputSize);
    if (kr != KERN_SUCCESS || outputStruct.result != 0) {
        return -1;
    }
    return 0;
}

int SMCWriteFanMode(int fanIndex, int forced) {
    char key[5];
    snprintf(key, sizeof(key), "F%dMd", fanIndex);
    unsigned char value = forced ? 1 : 0;
    return smcWriteBytes(key, stringToKey("ui8 "), &value, sizeof(value));
}

int SMCWriteFanTargetRPM(int fanIndex, float rpm) {
    char key[5];
    snprintf(key, sizeof(key), "F%dTg", fanIndex);
    unsigned char bytes[sizeof(rpm)];
    memcpy(bytes, &rpm, sizeof(rpm));
    return smcWriteBytes(key, stringToKey("flt "), bytes, sizeof(rpm));
}

int SMCGetFanCount(void) {
    double value = smcReadNumericValue("FNum");
    if (value < 0) {
        return 0;
    }
    return (int)value;
}
