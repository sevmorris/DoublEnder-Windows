/*
 * What a WASAPI capture endpoint is plugged into, for telling a USB mic from
 * Bluetooth earbuds. Endpoint names don't say reliably ("Headset (…)" can be
 * either), so this follows the endpoint's device topology to the controller
 * it connects to and reads that controller's Plug and Play instance ID, as
 * Chromium's CoreAudioUtil::GetAudioControllerID does. Windows only.
 */
#if defined(_WIN32)

#define COBJMACROS
#include <windows.h>
#include <objbase.h>
#include <propidl.h>
#include <mmdeviceapi.h>
#include <devicetopology.h>

#include <string.h>

/* Defined here rather than taken from uuid.lib or initguid.h, so nothing
   depends on how the SDK's GUIDs are linked. */
static const CLSID DE_CLSID_MMDeviceEnumerator = {0xBCDE0395, 0xE52F, 0x467C, {0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E}};
static const IID DE_IID_IMMDeviceEnumerator = {0xA95664D2, 0x9614, 0x4F35, {0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6}};
static const IID DE_IID_IDeviceTopology = {0x2A07407E, 0x6497, 0x4A18, {0x97, 0x87, 0x32, 0xF7, 0x9B, 0xD0, 0xD9, 0x8F}};
static const PROPERTYKEY DE_PKEY_Device_InstanceId = {{0x78C34FC8, 0x104A, 0x4ACA, {0x9E, 0xA4, 0x52, 0x4D, 0x52, 0x99, 0x6E, 0x57}}, 256};

void de_win_endpoint_controller(const wchar_t* endpointID, char* out, size_t capacity)
{
    /* Enumeration runs on a worker thread; join (or create) the MTA there,
       as miniaudio's own context does on its thread. */
    HRESULT init = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    IMMDeviceEnumerator* enumerator = NULL;
    IMMDevice* endpoint = NULL;
    IDeviceTopology* topology = NULL;
    IConnector* connector = NULL;
    LPWSTR connectedID = NULL;
    IMMDevice* controller = NULL;
    IPropertyStore* properties = NULL;
    PROPVARIANT value;

    PropVariantInit(&value);
    out[0] = '\0';
    /* The first connector is enough: an endpoint with several has no single
       answer anyway. */
    if (SUCCEEDED(CoCreateInstance(&DE_CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL,
                                   &DE_IID_IMMDeviceEnumerator, (void**)&enumerator))
        && SUCCEEDED(IMMDeviceEnumerator_GetDevice(enumerator, endpointID, &endpoint))
        && SUCCEEDED(IMMDevice_Activate(endpoint, &DE_IID_IDeviceTopology, CLSCTX_ALL, NULL, (void**)&topology))
        && SUCCEEDED(IDeviceTopology_GetConnector(topology, 0, &connector))
        && SUCCEEDED(IConnector_GetDeviceIdConnectedTo(connector, &connectedID))
        && SUCCEEDED(IMMDeviceEnumerator_GetDevice(enumerator, connectedID, &controller))
        && SUCCEEDED(IMMDevice_OpenPropertyStore(controller, STGM_READ, &properties))
        && SUCCEEDED(IPropertyStore_GetValue(properties, &DE_PKEY_Device_InstanceId, &value))
        && value.vt == VT_LPWSTR && value.pwszVal != NULL) {
        if (WideCharToMultiByte(CP_UTF8, 0, value.pwszVal, -1, out, (int)capacity, NULL, NULL) == 0) {
            out[0] = '\0';  /* didn't fit: say nothing rather than half */
        }
    }

    PropVariantClear(&value);
    if (properties != NULL) IPropertyStore_Release(properties);
    if (controller != NULL) IMMDevice_Release(controller);
    if (connectedID != NULL) CoTaskMemFree(connectedID);
    if (connector != NULL) IConnector_Release(connector);
    if (topology != NULL) IDeviceTopology_Release(topology);
    if (endpoint != NULL) IMMDevice_Release(endpoint);
    if (enumerator != NULL) IMMDeviceEnumerator_Release(enumerator);
    if (SUCCEEDED(init)) {
        CoUninitialize();
    }
}

#else

/* Nothing to do elsewhere; keeps the translation unit non-empty. */
typedef int de_audio_win_unused;

#endif
