#ifndef Telegram_NetworkLogging_h
#define Telegram_NetworkLogging_h

#import <Foundation/Foundation.h>

void NetworkRegisterLoggingFunction();

void setBridgingTraceFunction(void (*)(NSString *, NSString *));

#endif
