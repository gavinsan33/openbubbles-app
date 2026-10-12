// The NDK has no AOSP liblog; fdk-aac only uses this for a SafetyNet log call.
#pragma once
#define android_errorWriteLog(tag, subTag) ((void)0)
