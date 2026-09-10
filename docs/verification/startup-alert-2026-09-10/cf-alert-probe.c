#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
int main(void) {
    CFOptionFlags resp = 0;
    SInt32 rc = CFUserNotificationDisplayAlert(
        12.0, kCFUserNotificationStopAlertLevel,
        NULL, NULL, NULL,
        CFSTR("RichOS could not start"),
        CFSTR("PROBE 2 - which display does CFUserNotificationDisplayAlert land on?"),
        CFSTR("OK"), NULL, NULL, &resp);
    printf("rc=%d resp=%lu\n", (int)rc, (unsigned long)resp);
    return 0;
}
