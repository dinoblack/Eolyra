// Eolyra audio driver (AudioServerPlugIn).
//
// Publica dois pares de dispositivos em loopback, cada par com um buffer em anel e um relógio
// compartilhados:
//
//   par "fone": "Eolyra" (saída visível, com volume/mute)  ->  "Eolyra Bridge Out" (entrada oculta)
//   par "mic":  "Eolyra Mic Bridge" (saída oculta)          ->  "Eolyra Mic" (entrada visível, com volume/mute)
//
// Os apps tocam em "Eolyra" e gravam de "Eolyra Mic"; o app Eolyra lê/escreve os lados
// ocultos e faz a ponte com o adaptador USB real.
//
// SPDX-License-Identifier: MIT

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define LL_EXPORT __attribute__((visibility("default")))

#define kManufacturer       "Eolyra"
#define kModelUID           "app.eolyra.model"
#define kRingFrames         32768
#define kZeroTimeStampFrames 16384
#define kMinDecibels        (-96.0f)

static const Float64 kSampleRates[] = { 44100.0, 48000.0, 88200.0, 96000.0 };
#define kSampleRateCount (sizeof(kSampleRates) / sizeof(kSampleRates[0]))

// MARK: - Objetos

enum {
    kID_PlugIn = kAudioObjectPlugInObject,
    kID_OutDevice, kID_OutStream, kID_OutVolume, kID_OutMute,
    kID_OutBridge, kID_OutBridgeStream,
    kID_MicBridge, kID_MicBridgeStream,
    kID_MicDevice, kID_MicStream, kID_MicVolume, kID_MicMute,
};

typedef struct {
    UInt32 channels;
    Float64 sampleRate;
    Float32 *ring;                 // kRingFrames * channels, intercalado
    _Atomic int64_t validStart;    // intervalo [validStart, validEnd) já escrito no anel
    _Atomic int64_t validEnd;
    UInt64 anchorHostTime;
    UInt32 ioClients;
} Pair;

typedef struct {
    AudioObjectID id, streamID, volumeID, muteID;   // volumeID/muteID = 0 quando não há controle
    const char *uid, *name;
    bool hidden;
    bool isInput;                  // direção do stream
    int pair;
    bool canBeDefault, canBeDefaultSystem;
    UInt32 terminalType;
    UInt32 ioClients;
    bool streamActive;
    Float32 volume;                // escalar 0..1
    bool muted;
    _Atomic Float32 gain;          // ganho linear aplicado na thread de IO
} Device;

static Pair gPairs[2] = {
    { .channels = 2, .sampleRate = 48000.0 },
    { .channels = 1, .sampleRate = 48000.0 },
};

static Device gDevices[4] = {
    { kID_OutDevice, kID_OutStream, kID_OutVolume, kID_OutMute, "app.eolyra.device.output", "Eolyra",
      false, false, 0, true, true, kAudioStreamTerminalTypeHeadphones, 0, true, 1, false, 1 },
    { kID_OutBridge, kID_OutBridgeStream, 0, 0, "app.eolyra.device.output.bridge", "Eolyra Bridge Out",
      true, true, 0, false, false, kAudioStreamTerminalTypeLine, 0, true, 1, false, 1 },
    { kID_MicBridge, kID_MicBridgeStream, 0, 0, "app.eolyra.device.mic.bridge", "Eolyra Mic Bridge",
      true, false, 1, false, false, kAudioStreamTerminalTypeLine, 0, true, 1, false, 1 },
    { kID_MicDevice, kID_MicStream, kID_MicVolume, kID_MicMute, "app.eolyra.device.mic", "Eolyra Mic",
      false, true, 1, true, false, kAudioStreamTerminalTypeMicrophone, 0, true, 1, false, 1 },
};
#define kDeviceCount 4

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;
static UInt32 gRefCount = 0;
static Float64 gHostTicksPerSecond = 0;

static Device *DeviceByID(AudioObjectID id) {
    for (int i = 0; i < kDeviceCount; i++) if (gDevices[i].id == id) return &gDevices[i];
    return NULL;
}
static Device *DeviceByStream(AudioObjectID id) {
    for (int i = 0; i < kDeviceCount; i++) if (gDevices[i].streamID == id) return &gDevices[i];
    return NULL;
}
static Device *DeviceByControl(AudioObjectID id, bool *isVolume) {
    for (int i = 0; i < kDeviceCount; i++) {
        if (gDevices[i].volumeID && gDevices[i].volumeID == id) { *isVolume = true; return &gDevices[i]; }
        if (gDevices[i].muteID && gDevices[i].muteID == id) { *isVolume = false; return &gDevices[i]; }
    }
    return NULL;
}
static AudioObjectPropertyScope DeviceScope(const Device *d) {
    return d->isInput ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
}

// MARK: - Volume (curva cúbica: amplitude = escalar³, ou seja dB = 60·log10(escalar))

static Float32 ScalarToDecibels(Float32 s) {
    if (s <= 0) return kMinDecibels;
    Float32 db = 60.0f * log10f(s);
    return db < kMinDecibels ? kMinDecibels : (db > 0 ? 0 : db);
}
static Float32 DecibelsToScalar(Float32 db) {
    if (db <= kMinDecibels) return 0;
    if (db >= 0) return 1;
    return powf(10.0f, db / 60.0f);
}
static void UpdateGain(Device *d) {
    Float32 g = d->muted ? 0 : d->volume * d->volume * d->volume;
    atomic_store(&d->gain, g);
}

// MARK: - Persistência (armazenamento do próprio coreaudiod)

static CFStringRef StorageKey(const Device *d, const char *suffix) {
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("%s.%s"), d->uid, suffix);
}
static void SaveControls(const Device *d) {
    if (!gHost) return;
    CFStringRef kv = StorageKey(d, "volume"), km = StorageKey(d, "mute");
    Float32 v = d->volume; SInt32 m = d->muted;
    CFNumberRef nv = CFNumberCreate(NULL, kCFNumberFloat32Type, &v);
    CFNumberRef nm = CFNumberCreate(NULL, kCFNumberSInt32Type, &m);
    gHost->WriteToStorage(gHost, kv, nv);
    gHost->WriteToStorage(gHost, km, nm);
    CFRelease(nv); CFRelease(nm); CFRelease(kv); CFRelease(km);
}
static void LoadControls(Device *d) {
    if (!gHost || !d->volumeID) return;
    CFPropertyListRef p = NULL;
    CFStringRef kv = StorageKey(d, "volume"), km = StorageKey(d, "mute");
    if (gHost->CopyFromStorage(gHost, kv, &p) == 0 && p) {
        if (CFGetTypeID(p) == CFNumberGetTypeID()) {
            Float32 v; CFNumberGetValue((CFNumberRef)p, kCFNumberFloat32Type, &v);
            d->volume = v < 0 ? 0 : (v > 1 ? 1 : v);
        }
        CFRelease(p); p = NULL;
    }
    if (gHost->CopyFromStorage(gHost, km, &p) == 0 && p) {
        if (CFGetTypeID(p) == CFNumberGetTypeID()) {
            SInt32 m; CFNumberGetValue((CFNumberRef)p, kCFNumberSInt32Type, &m);
            d->muted = m != 0;
        }
        CFRelease(p);
    }
    CFRelease(kv); CFRelease(km);
}

// MARK: - Formatos

static AudioStreamBasicDescription FormatFor(const Pair *p, Float64 rate) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = rate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
    f.mBytesPerPacket = 4 * p->channels;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = 4 * p->channels;
    f.mChannelsPerFrame = p->channels;
    f.mBitsPerChannel = 32;
    return f;
}
static bool IsSupportedRate(Float64 r) {
    for (UInt32 i = 0; i < kSampleRateCount; i++) if (kSampleRates[i] == r) return true;
    return false;
}

// MARK: - Propriedades
//
// Uma única função responde tamanho e valor: com `out == NULL` só calcula `*outSize`.

#define NEED(sz) do { UInt32 _n = (UInt32)(sz); if (out && inSize < _n) return kAudioHardwareBadPropertySizeError; *outSize = _n; } while (0)
#define PUT(type, value) do { NEED(sizeof(type)); if (out) *(type *)out = (value); return 0; } while (0)
#define PUT_STRING(cstr) do { NEED(sizeof(CFStringRef)); if (out) *(CFStringRef *)out = CFStringCreateWithCString(NULL, (cstr), kCFStringEncodingUTF8); return 0; } while (0)

static OSStatus PutIDs(const AudioObjectID *ids, UInt32 n, UInt32 inSize, UInt32 *outSize, void *out) {
    if (out) {
        UInt32 fit = inSize / sizeof(AudioObjectID);
        if (n > fit) n = fit;
        memcpy(out, ids, n * sizeof(AudioObjectID));
    }
    *outSize = n * sizeof(AudioObjectID);
    return 0;
}

static OSStatus PlugInProperty(const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q,
                               UInt32 inSize, UInt32 *outSize, void *out) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioPlugInClassID);
    case kAudioObjectPropertyOwner: PUT(AudioObjectID, kAudioObjectUnknown);
    case kAudioObjectPropertyManufacturer: PUT_STRING(kManufacturer);
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList: {
        AudioObjectID ids[kDeviceCount];
        for (int i = 0; i < kDeviceCount; i++) ids[i] = gDevices[i].id;
        return PutIDs(ids, kDeviceCount, inSize, outSize, out);
    }
    case kAudioPlugInPropertyBoxList: *outSize = 0; return 0;
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        NEED(sizeof(AudioObjectID));
        if (out) {
            AudioObjectID found = kAudioObjectUnknown;
            if (q && qSize >= sizeof(CFStringRef)) {
                CFStringRef uid = *(const CFStringRef *)q;
                for (int i = 0; i < kDeviceCount; i++) {
                    CFStringRef mine = CFStringCreateWithCString(NULL, gDevices[i].uid, kCFStringEncodingUTF8);
                    bool eq = uid && CFStringCompare(uid, mine, 0) == kCFCompareEqualTo;
                    CFRelease(mine);
                    if (eq) { found = gDevices[i].id; break; }
                }
            }
            *(AudioObjectID *)out = found;
        }
        return 0;
    }
    case kAudioPlugInPropertyResourceBundle: PUT_STRING("");
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus DeviceProperty(Device *d, const AudioObjectPropertyAddress *a,
                               UInt32 inSize, UInt32 *outSize, void *out) {
    Pair *p = &gPairs[d->pair];
    AudioObjectPropertyScope scope = a->mScope;
    bool scopeMatches = scope == kAudioObjectPropertyScopeGlobal || scope == DeviceScope(d);

    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioDeviceClassID);
    case kAudioObjectPropertyOwner: PUT(AudioObjectID, kID_PlugIn);
    case kAudioObjectPropertyName: PUT_STRING(d->name);
    case kAudioObjectPropertyManufacturer: PUT_STRING(kManufacturer);
    case kAudioDevicePropertyDeviceUID: PUT_STRING(d->uid);
    case kAudioDevicePropertyModelUID: PUT_STRING(kModelUID);
    case kAudioDevicePropertyTransportType: PUT(UInt32, kAudioDeviceTransportTypeVirtual);
    case kAudioDevicePropertyRelatedDevices: { AudioObjectID id = d->id; return PutIDs(&id, 1, inSize, outSize, out); }
    case kAudioDevicePropertyClockDomain: PUT(UInt32, 0);
    case kAudioDevicePropertyDeviceIsAlive: PUT(UInt32, 1);
    case kAudioDevicePropertyDeviceIsRunning: PUT(UInt32, d->ioClients > 0);
    case kAudioDevicePropertyDeviceCanBeDefaultDevice: PUT(UInt32, d->canBeDefault);
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: PUT(UInt32, d->canBeDefaultSystem);
    case kAudioDevicePropertyLatency: PUT(UInt32, 0);
    case kAudioDevicePropertySafetyOffset: PUT(UInt32, 0);
    case kAudioDevicePropertyIsHidden: PUT(UInt32, d->hidden);
    case kAudioDevicePropertyZeroTimeStampPeriod: PUT(UInt32, kZeroTimeStampFrames);
    case kAudioDevicePropertyNominalSampleRate: PUT(Float64, p->sampleRate);
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        UInt32 n = kSampleRateCount;
        if (out) { UInt32 fit = inSize / sizeof(AudioValueRange); if (n > fit) n = fit; }
        if (out) for (UInt32 i = 0; i < n; i++) ((AudioValueRange *)out)[i] = (AudioValueRange){ kSampleRates[i], kSampleRates[i] };
        *outSize = n * sizeof(AudioValueRange);
        return 0;
    }
    case kAudioDevicePropertyStreams: {
        AudioObjectID id = d->streamID;
        return PutIDs(&id, scopeMatches ? 1 : 0, inSize, outSize, out);
    }
    case kAudioObjectPropertyControlList:
    case kAudioObjectPropertyOwnedObjects: {
        AudioObjectID ids[3]; UInt32 n = 0;
        if (a->mSelector == kAudioObjectPropertyOwnedObjects && scopeMatches) ids[n++] = d->streamID;
        if (scopeMatches && d->volumeID) { ids[n++] = d->volumeID; ids[n++] = d->muteID; }
        return PutIDs(ids, n, inSize, outSize, out);
    }
    case kAudioDevicePropertyPreferredChannelsForStereo: {
        NEED(2 * sizeof(UInt32));
        if (out) { ((UInt32 *)out)[0] = 1; ((UInt32 *)out)[1] = p->channels > 1 ? 2 : 1; }
        return 0;
    }
    case kAudioDevicePropertyPreferredChannelLayout: {
        UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + p->channels * sizeof(AudioChannelDescription));
        NEED(size);
        if (out) {
            AudioChannelLayout *l = (AudioChannelLayout *)out;
            memset(l, 0, size);
            l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            l->mNumberChannelDescriptions = p->channels;
            if (p->channels == 1) l->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Mono;
            else { l->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
                   l->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right; }
        }
        return 0;
    }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus StreamProperty(Device *d, const AudioObjectPropertyAddress *a,
                               UInt32 inSize, UInt32 *outSize, void *out) {
    Pair *p = &gPairs[d->pair];
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioStreamClassID);
    case kAudioObjectPropertyOwner: PUT(AudioObjectID, d->id);
    case kAudioObjectPropertyOwnedObjects: *outSize = 0; return 0;
    case kAudioStreamPropertyIsActive: PUT(UInt32, d->streamActive);
    case kAudioStreamPropertyDirection: PUT(UInt32, d->isInput ? 1 : 0);
    case kAudioStreamPropertyTerminalType: PUT(UInt32, d->terminalType);
    case kAudioStreamPropertyStartingChannel: PUT(UInt32, 1);
    case kAudioStreamPropertyLatency: PUT(UInt32, 0);
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: PUT(AudioStreamBasicDescription, FormatFor(p, p->sampleRate));
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        UInt32 n = kSampleRateCount;
        if (out) { UInt32 fit = inSize / sizeof(AudioStreamRangedDescription); if (n > fit) n = fit; }
        if (out) for (UInt32 i = 0; i < n; i++) {
            AudioStreamRangedDescription *r = &((AudioStreamRangedDescription *)out)[i];
            r->mFormat = FormatFor(p, kSampleRates[i]);
            r->mSampleRateRange = (AudioValueRange){ kSampleRates[i], kSampleRates[i] };
        }
        *outSize = n * sizeof(AudioStreamRangedDescription);
        return 0;
    }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus ControlProperty(Device *d, bool isVolume, const AudioObjectPropertyAddress *a,
                                UInt32 inSize, UInt32 *outSize, void *out) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: PUT(AudioClassID, isVolume ? kAudioLevelControlClassID : kAudioBooleanControlClassID);
    case kAudioObjectPropertyClass: PUT(AudioClassID, isVolume ? kAudioVolumeControlClassID : kAudioMuteControlClassID);
    case kAudioObjectPropertyOwner: PUT(AudioObjectID, d->id);
    case kAudioObjectPropertyOwnedObjects: *outSize = 0; return 0;
    case kAudioControlPropertyScope: PUT(AudioObjectPropertyScope, DeviceScope(d));
    case kAudioControlPropertyElement: PUT(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
    }
    if (isVolume) {
        switch (a->mSelector) {
        case kAudioLevelControlPropertyScalarValue: PUT(Float32, d->volume);
        case kAudioLevelControlPropertyDecibelValue: PUT(Float32, ScalarToDecibels(d->volume));
        case kAudioLevelControlPropertyDecibelRange: PUT(AudioValueRange, ((AudioValueRange){ kMinDecibels, 0 }));
        case kAudioLevelControlPropertyConvertScalarToDecibels:
            NEED(sizeof(Float32)); if (out) *(Float32 *)out = ScalarToDecibels(*(Float32 *)out); return 0;
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            NEED(sizeof(Float32)); if (out) *(Float32 *)out = DecibelsToScalar(*(Float32 *)out); return 0;
        }
    } else if (a->mSelector == kAudioBooleanControlPropertyValue) {
        PUT(UInt32, d->muted);
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus Property(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q,
                         UInt32 inSize, UInt32 *outSize, void *out) {
    if (!a || !outSize) return kAudioHardwareIllegalOperationError;
    if (obj == kID_PlugIn) return PlugInProperty(a, qSize, q, inSize, outSize, out);
    Device *d;
    bool isVolume;
    if ((d = DeviceByID(obj))) return DeviceProperty(d, a, inSize, outSize, out);
    if ((d = DeviceByStream(obj))) return StreamProperty(d, a, inSize, outSize, out);
    if ((d = DeviceByControl(obj, &isVolume))) return ControlProperty(d, isVolume, a, inSize, outSize, out);
    return kAudioHardwareBadObjectError;
}

// MARK: - Interface do driver

static HRESULT LL_QueryInterface(void *self, REFIID uuid, LPVOID *outInterface);
static ULONG LL_AddRef(void *self);
static ULONG LL_Release(void *self);
static OSStatus LL_Initialize(AudioServerPlugInDriverRef self, AudioServerPlugInHostRef host);
static OSStatus LL_CreateDevice(AudioServerPlugInDriverRef self, CFDictionaryRef desc, const AudioServerPlugInClientInfo *client, AudioObjectID *outID);
static OSStatus LL_DestroyDevice(AudioServerPlugInDriverRef self, AudioObjectID dev);
static OSStatus LL_AddDeviceClient(AudioServerPlugInDriverRef self, AudioObjectID dev, const AudioServerPlugInClientInfo *client);
static OSStatus LL_RemoveDeviceClient(AudioServerPlugInDriverRef self, AudioObjectID dev, const AudioServerPlugInClientInfo *client);
static OSStatus LL_PerformConfigChange(AudioServerPlugInDriverRef self, AudioObjectID dev, UInt64 action, void *info);
static OSStatus LL_AbortConfigChange(AudioServerPlugInDriverRef self, AudioObjectID dev, UInt64 action, void *info);
static Boolean LL_HasProperty(AudioServerPlugInDriverRef self, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a);
static OSStatus LL_IsPropertySettable(AudioServerPlugInDriverRef self, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *out);
static OSStatus LL_GetPropertyDataSize(AudioServerPlugInDriverRef self, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q, UInt32 *outSize);
static OSStatus LL_GetPropertyData(AudioServerPlugInDriverRef self, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q, UInt32 inSize, UInt32 *outSize, void *out);
static OSStatus LL_SetPropertyData(AudioServerPlugInDriverRef self, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q, UInt32 inSize, const void *in);
static OSStatus LL_StartIO(AudioServerPlugInDriverRef self, AudioObjectID dev, UInt32 client);
static OSStatus LL_StopIO(AudioServerPlugInDriverRef self, AudioObjectID dev, UInt32 client);
static OSStatus LL_GetZeroTimeStamp(AudioServerPlugInDriverRef self, AudioObjectID dev, UInt32 client, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus LL_WillDoIOOperation(AudioServerPlugInDriverRef self, AudioObjectID dev, UInt32 client, UInt32 op, Boolean *outWillDo, Boolean *outInPlace);
static OSStatus LL_BeginIOOperation(AudioServerPlugInDriverRef self, AudioObjectID dev, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle);
static OSStatus LL_DoIOOperation(AudioServerPlugInDriverRef self, AudioObjectID dev, AudioObjectID stream, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle, void *mainBuffer, void *secondaryBuffer);
static OSStatus LL_EndIOOperation(AudioServerPlugInDriverRef self, AudioObjectID dev, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle);

static AudioServerPlugInDriverInterface gInterface = {
    NULL, LL_QueryInterface, LL_AddRef, LL_Release, LL_Initialize, LL_CreateDevice, LL_DestroyDevice,
    LL_AddDeviceClient, LL_RemoveDeviceClient, LL_PerformConfigChange, LL_AbortConfigChange,
    LL_HasProperty, LL_IsPropertySettable, LL_GetPropertyDataSize, LL_GetPropertyData, LL_SetPropertyData,
    LL_StartIO, LL_StopIO, LL_GetZeroTimeStamp, LL_WillDoIOOperation, LL_BeginIOOperation, LL_DoIOOperation,
    LL_EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriver = &gInterfacePtr;

LL_EXPORT void *Eolyra_Create(CFAllocatorRef allocator, CFUUIDRef requestedType) {
    (void)allocator;
    return CFEqual(requestedType, kAudioServerPlugInTypeUUID) ? gDriver : NULL;
}

static HRESULT LL_QueryInterface(void *self, REFIID uuid, LPVOID *outInterface) {
    if (self != gDriver || !outInterface) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex); gRefCount++; pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriver;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG LL_AddRef(void *self) {
    if (self != gDriver) return 0;
    pthread_mutex_lock(&gStateMutex); ULONG r = ++gRefCount; pthread_mutex_unlock(&gStateMutex);
    return r;
}

static ULONG LL_Release(void *self) {
    if (self != gDriver) return 0;
    pthread_mutex_lock(&gStateMutex); ULONG r = gRefCount > 0 ? --gRefCount : 0; pthread_mutex_unlock(&gStateMutex);
    return r;
}

static OSStatus LL_Initialize(AudioServerPlugInDriverRef self, AudioServerPlugInHostRef host) {
    if (self != gDriver) return kAudioHardwareBadObjectError;
    gHost = host;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    gHostTicksPerSecond = 1e9 * (Float64)tb.denom / (Float64)tb.numer;
    for (int i = 0; i < 2; i++) {
        gPairs[i].ring = calloc((size_t)kRingFrames * gPairs[i].channels, sizeof(Float32));
        if (!gPairs[i].ring) return kAudioHardwareUnspecifiedError;
    }
    for (int i = 0; i < kDeviceCount; i++) { LoadControls(&gDevices[i]); UpdateGain(&gDevices[i]); }
    return 0;
}

static OSStatus LL_CreateDevice(AudioServerPlugInDriverRef self, CFDictionaryRef desc, const AudioServerPlugInClientInfo *client, AudioObjectID *outID) {
    (void)self; (void)desc; (void)client; (void)outID;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus LL_DestroyDevice(AudioServerPlugInDriverRef self, AudioObjectID dev) {
    (void)self; (void)dev;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus LL_AddDeviceClient(AudioServerPlugInDriverRef self, AudioObjectID dev, const AudioServerPlugInClientInfo *client) {
    (void)client;
    return self == gDriver && DeviceByID(dev) ? 0 : kAudioHardwareBadObjectError;
}
static OSStatus LL_RemoveDeviceClient(AudioServerPlugInDriverRef self, AudioObjectID dev, const AudioServerPlugInClientInfo *client) {
    (void)client;
    return self == gDriver && DeviceByID(dev) ? 0 : kAudioHardwareBadObjectError;
}

static void ResetPair(Pair *p) {
    memset(p->ring, 0, (size_t)kRingFrames * p->channels * sizeof(Float32));
    atomic_store(&p->validStart, 0);
    atomic_store(&p->validEnd, 0);
}

// A troca de taxa de amostragem vale para o par inteiro (os dois lados compartilham relógio e anel).
static OSStatus LL_PerformConfigChange(AudioServerPlugInDriverRef self, AudioObjectID dev, UInt64 action, void *info) {
    (void)info;
    Device *d = DeviceByID(dev);
    if (self != gDriver || !d) return kAudioHardwareBadObjectError;
    Float64 rate = (Float64)action;
    if (!IsSupportedRate(rate)) return kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&gStateMutex);
    Pair *p = &gPairs[d->pair];
    if (p->sampleRate != rate) { p->sampleRate = rate; ResetPair(p); }
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}
static OSStatus LL_AbortConfigChange(AudioServerPlugInDriverRef self, AudioObjectID dev, UInt64 action, void *info) {
    (void)self; (void)dev; (void)action; (void)info;
    return 0;
}

static Boolean LL_HasProperty(AudioServerPlugInDriverRef self, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a) {
    (void)pid;
    if (self != gDriver) return false;
    UInt32 size = 0;
    return Property(obj, a, 0, NULL, 0, &size, NULL) == 0;
}

static OSStatus LL_IsPropertySettable(AudioServerPlugInDriverRef self, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *out) {
    (void)pid;
    if (self != gDriver || !a || !out) return kAudioHardwareIllegalOperationError;
    UInt32 size = 0;
    OSStatus st = Property(obj, a, 0, NULL, 0, &size, NULL);
    if (st) return st;
    bool isVolume;
    *out = false;
    if (DeviceByID(obj)) *out = a->mSelector == kAudioDevicePropertyNominalSampleRate;
    else if (DeviceByStream(obj))
        *out = a->mSelector == kAudioStreamPropertyIsActive || a->mSelector == kAudioStreamPropertyVirtualFormat
            || a->mSelector == kAudioStreamPropertyPhysicalFormat;
    else if (DeviceByControl(obj, &isVolume))
        *out = isVolume ? (a->mSelector == kAudioLevelControlPropertyScalarValue || a->mSelector == kAudioLevelControlPropertyDecibelValue)
                        : a->mSelector == kAudioBooleanControlPropertyValue;
    return 0;
}

static OSStatus LL_GetPropertyDataSize(AudioServerPlugInDriverRef self, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q, UInt32 *outSize) {
    (void)pid;
    if (self != gDriver) return kAudioHardwareBadObjectError;
    return Property(obj, a, qSize, q, 0, outSize, NULL);
}

static OSStatus LL_GetPropertyData(AudioServerPlugInDriverRef self, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q, UInt32 inSize, UInt32 *outSize, void *out) {
    (void)pid;
    if (self != gDriver || !out) return kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&gStateMutex);
    OSStatus st = Property(obj, a, qSize, q, inSize, outSize, out);
    pthread_mutex_unlock(&gStateMutex);
    return st;
}

static void RequestRate(Device *d, Float64 rate) {
    for (int i = 0; i < kDeviceCount; i++)
        if (gDevices[i].pair == d->pair) gHost->RequestDeviceConfigurationChange(gHost, gDevices[i].id, (UInt64)rate, NULL);
}

static OSStatus LL_SetPropertyData(AudioServerPlugInDriverRef self, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qSize, const void *q, UInt32 inSize, const void *in) {
    (void)pid; (void)qSize; (void)q;
    if (self != gDriver || !a || !in) return kAudioHardwareIllegalOperationError;
    Device *d;
    bool isVolume;

    if ((d = DeviceByID(obj))) {
        if (a->mSelector != kAudioDevicePropertyNominalSampleRate) return kAudioHardwareUnknownPropertyError;
        if (inSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        Float64 rate = *(const Float64 *)in;
        if (!IsSupportedRate(rate)) return kAudioHardwareIllegalOperationError;
        if (rate != gPairs[d->pair].sampleRate) RequestRate(d, rate);
        return 0;
    }

    if ((d = DeviceByStream(obj))) {
        switch (a->mSelector) {
        case kAudioStreamPropertyIsActive:
            if (inSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            pthread_mutex_lock(&gStateMutex); d->streamActive = *(const UInt32 *)in != 0; pthread_mutex_unlock(&gStateMutex);
            return 0;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            if (inSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            const AudioStreamBasicDescription *f = (const AudioStreamBasicDescription *)in;
            AudioStreamBasicDescription want = FormatFor(&gPairs[d->pair], f->mSampleRate);
            if (f->mFormatID != want.mFormatID || f->mChannelsPerFrame != want.mChannelsPerFrame
                || f->mBitsPerChannel != want.mBitsPerChannel || !IsSupportedRate(f->mSampleRate))
                return kAudioDeviceUnsupportedFormatError;
            if (f->mSampleRate != gPairs[d->pair].sampleRate) RequestRate(d, f->mSampleRate);
            return 0;
        }
        }
        return kAudioHardwareUnknownPropertyError;
    }

    if ((d = DeviceByControl(obj, &isVolume))) {
        AudioObjectPropertyAddress changed[2];
        UInt32 n = 0;
        pthread_mutex_lock(&gStateMutex);
        if (isVolume && (a->mSelector == kAudioLevelControlPropertyScalarValue || a->mSelector == kAudioLevelControlPropertyDecibelValue)) {
            if (inSize < sizeof(Float32)) { pthread_mutex_unlock(&gStateMutex); return kAudioHardwareBadPropertySizeError; }
            Float32 v = *(const Float32 *)in;
            if (a->mSelector == kAudioLevelControlPropertyDecibelValue) v = DecibelsToScalar(v);
            v = v < 0 ? 0 : (v > 1 ? 1 : v);
            if (v != d->volume) {
                d->volume = v;
                changed[n++] = (AudioObjectPropertyAddress){ kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                changed[n++] = (AudioObjectPropertyAddress){ kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            }
        } else if (!isVolume && a->mSelector == kAudioBooleanControlPropertyValue) {
            if (inSize < sizeof(UInt32)) { pthread_mutex_unlock(&gStateMutex); return kAudioHardwareBadPropertySizeError; }
            bool m = *(const UInt32 *)in != 0;
            if (m != d->muted) {
                d->muted = m;
                changed[n++] = (AudioObjectPropertyAddress){ kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            }
        } else {
            pthread_mutex_unlock(&gStateMutex);
            return kAudioHardwareUnknownPropertyError;
        }
        UpdateGain(d);
        pthread_mutex_unlock(&gStateMutex);
        if (n) { SaveControls(d); gHost->PropertiesChanged(gHost, obj, n, changed); }
        return 0;
    }
    return kAudioHardwareBadObjectError;
}

// MARK: - IO

static OSStatus LL_StartIO(AudioServerPlugInDriverRef self, AudioObjectID dev, UInt32 client) {
    (void)client;
    Device *d = DeviceByID(dev);
    if (self != gDriver || !d) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    Pair *p = &gPairs[d->pair];
    if (p->ioClients++ == 0) {
        ResetPair(p);
        p->anchorHostTime = mach_absolute_time();
    }
    d->ioClients++;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus LL_StopIO(AudioServerPlugInDriverRef self, AudioObjectID dev, UInt32 client) {
    (void)client;
    Device *d = DeviceByID(dev);
    if (self != gDriver || !d) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (d->ioClients > 0) d->ioClients--;
    if (gPairs[d->pair].ioClients > 0) gPairs[d->pair].ioClients--;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

// Relógio do par: um "tick" a cada kZeroTimeStampFrames amostras desde o início do IO.
static OSStatus LL_GetZeroTimeStamp(AudioServerPlugInDriverRef self, AudioObjectID dev, UInt32 client, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)client;
    Device *d = DeviceByID(dev);
    if (self != gDriver || !d) return kAudioHardwareBadObjectError;
    Pair *p = &gPairs[d->pair];
    Float64 ticksPerPeriod = gHostTicksPerSecond / p->sampleRate * kZeroTimeStampFrames;
    UInt64 now = mach_absolute_time();
    UInt64 elapsed = now > p->anchorHostTime ? now - p->anchorHostTime : 0;
    UInt64 periods = (UInt64)((Float64)elapsed / ticksPerPeriod);
    *outSampleTime = (Float64)(periods * kZeroTimeStampFrames);
    *outHostTime = p->anchorHostTime + (UInt64)((Float64)periods * ticksPerPeriod);
    *outSeed = 1;
    return 0;
}

static OSStatus LL_WillDoIOOperation(AudioServerPlugInDriverRef self, AudioObjectID dev, UInt32 client, UInt32 op, Boolean *outWillDo, Boolean *outInPlace) {
    (void)client;
    Device *d = DeviceByID(dev);
    if (self != gDriver || !d || !outWillDo || !outInPlace) return kAudioHardwareBadObjectError;
    *outWillDo = (d->isInput && op == kAudioServerPlugInIOOperationReadInput)
              || (!d->isInput && op == kAudioServerPlugInIOOperationWriteMix);
    *outInPlace = true;
    return 0;
}

static OSStatus LL_BeginIOOperation(AudioServerPlugInDriverRef self, AudioObjectID dev, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
    (void)client; (void)op; (void)frames; (void)cycle;
    return self == gDriver && DeviceByID(dev) ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus LL_EndIOOperation(AudioServerPlugInDriverRef self, AudioObjectID dev, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
    (void)client; (void)op; (void)frames; (void)cycle;
    return self == gDriver && DeviceByID(dev) ? 0 : kAudioHardwareBadObjectError;
}

// Escritor: copia (com ganho) para o anel e estende o intervalo válido.
static void WriteRing(Pair *p, const Float32 *src, UInt32 frames, int64_t start, Float32 gain) {
    UInt32 ch = p->channels;
    for (UInt32 f = 0; f < frames; f++) {
        Float32 *dst = p->ring + (size_t)((uint64_t)(start + f) % kRingFrames) * ch;
        for (UInt32 c = 0; c < ch; c++) dst[c] = src[f * ch + c] * gain;
    }
    if (atomic_load(&p->validEnd) != start) atomic_store(&p->validStart, start);  // houve uma lacuna
    atomic_store(&p->validEnd, start + frames);
}

// Leitor: amostras fora do intervalo válido (nunca escritas ou já sobrescritas) viram silêncio.
static void ReadRing(Pair *p, Float32 *dst, UInt32 frames, int64_t start, Float32 gain) {
    UInt32 ch = p->channels;
    int64_t end = atomic_load(&p->validEnd);
    int64_t begin = atomic_load(&p->validStart);
    if (begin < end - kRingFrames) begin = end - kRingFrames;
    for (UInt32 f = 0; f < frames; f++) {
        int64_t t = start + f;
        if (t >= begin && t < end) {
            const Float32 *src = p->ring + (size_t)((uint64_t)t % kRingFrames) * ch;
            for (UInt32 c = 0; c < ch; c++) dst[f * ch + c] = src[c] * gain;
        } else {
            for (UInt32 c = 0; c < ch; c++) dst[f * ch + c] = 0;
        }
    }
}

static OSStatus LL_DoIOOperation(AudioServerPlugInDriverRef self, AudioObjectID dev, AudioObjectID stream, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle, void *mainBuffer, void *secondaryBuffer) {
    (void)client; (void)secondaryBuffer;
    Device *d = DeviceByID(dev);
    if (self != gDriver || !d || stream != d->streamID || !mainBuffer || !cycle) return kAudioHardwareBadObjectError;
    Pair *p = &gPairs[d->pair];
    Float32 gain = atomic_load(&d->gain);
    if (op == kAudioServerPlugInIOOperationWriteMix && !d->isInput)
        WriteRing(p, (const Float32 *)mainBuffer, frames, (int64_t)cycle->mOutputTime.mSampleTime, gain);
    else if (op == kAudioServerPlugInIOOperationReadInput && d->isInput)
        ReadRing(p, (Float32 *)mainBuffer, frames, (int64_t)cycle->mInputTime.mSampleTime, gain);
    return 0;
}
