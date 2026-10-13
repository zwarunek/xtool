// TargetConditionals.h for Metal shaders compiled by xtool-metal.
#ifndef __XT_TARGET_CONDITIONALS
#define __XT_TARGET_CONDITIONALS
#define TARGET_OS_MAC 1
#define TARGET_OS_DARWIN 1
#if defined(__METAL_MACOS__)
#define TARGET_OS_OSX 1
#define TARGET_OS_IPHONE 0
#define TARGET_OS_IOS 0
#else
#define TARGET_OS_OSX 0
#define TARGET_OS_IPHONE 1
#define TARGET_OS_IOS (defined(__METAL_IOS__))
#endif
#if defined(__METAL_TVOS__)
#define TARGET_OS_TV 1
#else
#define TARGET_OS_TV 0
#endif
#if defined(__METAL_WATCHOS__)
#define TARGET_OS_WATCH 1
#else
#define TARGET_OS_WATCH 0
#endif
#if defined(__METAL_XROS__)
#define TARGET_OS_VISION 1
#define TARGET_OS_XR 1
#else
#define TARGET_OS_VISION 0
#define TARGET_OS_XR 0
#endif
#define TARGET_OS_MACCATALYST 0
#define TARGET_OS_UIKITFORMAC 0
#ifdef __XT_SIMULATOR__
#define TARGET_OS_SIMULATOR 1
#else
#define TARGET_OS_SIMULATOR 0
#endif
#define TARGET_OS_EMBEDDED 0
#define TARGET_RT_LITTLE_ENDIAN 1
#define TARGET_RT_64_BIT 1
#endif
