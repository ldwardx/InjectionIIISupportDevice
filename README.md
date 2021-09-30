# Injection support both device and simulator

![Icon](http://johnholdsworth.com/Syringe_128.png)

Thanks [johnno1962](https://github.com/johnno1962)
Injection: https://github.com/johnno1962/InjectionIII

Support iOS13+ device.

1. ```applicationDidFinishLaunching:``` add below code
```Objc
#if DEBUG
#if TARGET_OS_SIMULATOR
    NSString *injectionBundlePath = @"/Applications/InjectionIII.app/Contents/Resources/iOSInjection.bundle";
#else
    NSString *injectionBundlePath = [[NSBundle mainBundle] pathForResource:@"iOSInjection_Device" ofType:@"bundle"];
#endif
    NSBundle *injectionBundle = [NSBundle bundleWithPath:injectionBundlePath];
    if (injectionBundle) {
        [injectionBundle load];
    } else {
        NSLog(@"Not Found Injection Bundle");
    }
#endif
```
2. ```Build Phase -> Run Script ``` run setup shell.
```shell
if [[ "$CONFIGURATION" = "Debug" && "$ARCHS" = "arm64" ]]; then
    InjectionSetup="/Applications/InjectionIII.app/Contents/Resources/InjectionSetup"
    if [[ -e "$InjectionSetup" ]]; then
        sh "$InjectionSetup"
    fi
fi
```
4. Done.
