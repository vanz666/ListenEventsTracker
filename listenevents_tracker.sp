#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <dhooks>

#pragma newdecls required

Handle g_detourCLCMsg_ListenEvents;

Handle g_callGetEventDescriptor;

Address g_gameEventManager;

public void OnPluginStart()
{
    GameData conf = new GameData("listenevents_tracker.games");
    
    if (conf == null) 
        SetFailState("Failed to load listenevents_tracker gamedata");
    
    StartPrepSDKCall(SDKCall_Static);
    
    if (!PrepSDKCall_SetFromConf(conf, SDKConf_Signature, "CreateInterface"))
        SetFailState("Failed to get CreateInterface");
        
    PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Pointer, VDECODE_FLAG_ALLOWNULL);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    
    char iface[64];
    
    if (!conf.GetKeyValue("GameEventManagerInterface", iface, sizeof(iface)))
        SetFailState("Failed to get gameeventmanager interface name");
    
    Handle call = EndPrepSDKCall();
    
    g_gameEventManager = SDKCall(call, iface, 0);
    
    delete call;
    
    if (!g_gameEventManager)
        SetFailState("Failed to get gameeventmanager ptr");
    
    StartPrepSDKCall(SDKCall_Raw);
        
    if (!PrepSDKCall_SetFromConf(conf, SDKConf_Signature, "CGameEventManager::GetEventDescriptor"))
        SetFailState("Failed to load CGameEventManager::GetEventDescriptor signature from gamedata");
        
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    g_callGetEventDescriptor = EndPrepSDKCall();
    
    if (!(g_detourCLCMsg_ListenEvents = DHookCreateFromConf(conf, "CBaseClient::CLCMsg_ListenEvents")))
        SetFailState("Failed to setup detour for CBaseClient::CLCMsg_ListenEvents");

    delete conf;
    
    if (!DHookEnableDetour(g_detourCLCMsg_ListenEvents, false, Detour_CLCMsg_ListenEvents))
        SetFailState("Failed to detour CBaseClient::CLCMsg_ListenEvents");
}

public MRESReturn Detour_CLCMsg_ListenEvents(Address thisPtr, Handle retn, Handle params)
{
    int client = LoadFromAddress(thisPtr + view_as<Address>(0x70), NumberType_Int32) + 1;
    
    if (!IsClientConnected(client))
        return MRES_Ignored;
    
    char name[MAX_NAME_LENGTH];
    char steamid[64];
    GetClientName(client, name, sizeof(name));
    GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid));
    
    LogMessage("========== CLCMsg_ListenEvents arrived from client %s (%s) ==========", name, steamid);
    
    int event_mask_size = DHookGetParamObjectPtrVar(params, 1, 0x0C, ObjectValueType_Int);
    Address event_mask_ptr = DHookGetParamObjectPtrVar(params, 1, 0x08, ObjectValueType_Int);
    int event_mask[16];
    
    for (int i = 0; i < event_mask_size && i < 16; i++)
        event_mask[i] = LoadFromAddress(event_mask_ptr + view_as<Address>(i * 0x04), NumberType_Int32);
    
    int index = BitVec512_FindNextSetBit(event_mask, 0);
    
    while (index >= 0)
    {
        Address descriptor = SDKCall(g_callGetEventDescriptor, g_gameEventManager, index);
    
        if (descriptor)
        {
            char eventName[64];
            GetEventDescName(descriptor, eventName, sizeof(eventName));
            
            LogMessage("%i: %s", index, eventName);
        }
        else
        {
            LogMessage("%i: unknown", index);
        }

        index = BitVec512_FindNextSetBit(event_mask, index + 1);
    }
    
    return MRES_Ignored;
}

void GetEventDescName(Address descriptor, char[] dest, int len)
{
    if (len > 0)
    {
        Address eventMap = LoadFromAddress(g_gameEventManager + view_as<Address>(0x78), NumberType_Int32);
        int elemIdx = LoadFromAddress(descriptor + view_as<Address>(0x04), NumberType_Int32);
        Address eventName = LoadFromAddress(eventMap + view_as<Address>(0x18 * elemIdx + 0x10), NumberType_Int32);
        
        int i;
        
        for (i = 0; i < len - 1; i++)
        {
            char chr = LoadFromAddress(eventName + view_as<Address>(i), NumberType_Int8);
        
            if (chr == '\0')
                break;
        
            dest[i] = chr;
        }
        
        dest[i] = '\0';
    }
}

int BitVec_FirstBitInWord(int elem, int offset)
{
    static const int firstBitLUT[256] = 
    {
        0,0,1,0,2,0,1,0,3,0,1,0,2,0,1,0,4,0,1,0,2,0,1,0,3,0,1,0,2,0,1,0,5,0,1,0,2,0,1,0,
        3,0,1,0,2,0,1,0,4,0,1,0,2,0,1,0,3,0,1,0,2,0,1,0,6,0,1,0,2,0,1,0,3,0,1,0,2,0,1,0,
        4,0,1,0,2,0,1,0,3,0,1,0,2,0,1,0,5,0,1,0,2,0,1,0,3,0,1,0,2,0,1,0,4,0,1,0,2,0,1,0,
        3,0,1,0,2,0,1,0,7,0,1,0,2,0,1,0,3,0,1,0,2,0,1,0,4,0,1,0,2,0,1,0,3,0,1,0,2,0,1,0,
        5,0,1,0,2,0,1,0,3,0,1,0,2,0,1,0,4,0,1,0,2,0,1,0,3,0,1,0,2,0,1,0,6,0,1,0,2,0,1,0,
        3,0,1,0,2,0,1,0,4,0,1,0,2,0,1,0,3,0,1,0,2,0,1,0,5,0,1,0,2,0,1,0,3,0,1,0,2,0,1,0,
        4,0,1,0,2,0,1,0,3,0,1,0,2,0,1,0
    };

    int elem_byte = (elem & 0xFF);

    if (elem_byte)
        return offset + firstBitLUT[elem_byte];

    elem >>>= 8;
    offset += 8;
    elem_byte = (elem & 0xFF);
    
    if (elem_byte)
        return offset + firstBitLUT[elem_byte];

    elem >>>= 8;
    offset += 8;
    elem_byte = (elem & 0xFF);
    
    if (elem_byte)
        return offset + firstBitLUT[elem_byte];

    elem >>>= 8;
    offset += 8;
    elem_byte = (elem & 0xFF);
    
    if (elem_byte)
        return offset + firstBitLUT[elem_byte];

    return -1;
}

int BitVec512_FindNextSetBit(int bit_vec[16], int start_bit)
{
    static const int start_mask[32] =
    {
        0xffffffff,
        0xfffffffe,
        0xfffffffc,
        0xfffffff8,
        0xfffffff0,
        0xffffffe0,
        0xffffffc0,
        0xffffff80,
        0xffffff00,
        0xfffffe00,
        0xfffffc00,
        0xfffff800,
        0xfffff000,
        0xffffe000,
        0xffffc000,
        0xffff8000,
        0xffff0000,
        0xfffe0000,
        0xfffc0000,
        0xfff80000,
        0xfff00000,
        0xffe00000,
        0xffc00000,
        0xff800000,
        0xff000000,
        0xfe000000,
        0xfc000000,
        0xf8000000,
        0xf0000000,
        0xe0000000,
        0xc0000000,
        0x80000000,
    };

    if (start_bit < 512)
    {
        int word_index = start_bit >> 5;
        int elem = bit_vec[word_index];
        elem &= start_mask[start_bit & 31];
        
        if (elem)
            return BitVec_FirstBitInWord(elem, word_index << 5);
        
        word_index++;
        
        while (word_index < 16)
        {
            elem = bit_vec[word_index];
        
            if (elem)
                return BitVec_FirstBitInWord(elem, word_index << 5);
                
            word_index++;
        }
    }
    
    return -1;
}
