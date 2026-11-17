# C-Shield Embedded Flutter SDK Integration - iOS Host App

The `c_shield_embedded` plugin does not bundle the XCFramework. The host app is
responsible for providing `CShieldEmbedded.xcframework` (Debug/Release variants)
and `OpenSSL.xcframework`.

---

## Requirements

- iOS 13.0+
- Xcode 15+
- CocoaPods

---

## Step 1 - Obtain the files from the CShield team

Obtain all of the following XCFramework files (all 3 are built specifically for
the customer's private key):

```
- CShieldEmbedded.xcframework    ← Release variant
- CShieldEmbedded.xcframework    ← Debug variant (same file name, distinguished by folder)
- OpenSSL.xcframework
```

---

## Step 2 - Organize the `Libs/` folder

Open the Flutter project's `ios` folder in Xcode via
`<your_app>/ios/Runner.xcworkspace`. Create a `Libs` folder inside `Runner`,
then create `Debug` and `Release` subfolders inside `Libs`:

```
Runner
├── Libs/                                       ← newly created folder
│   ├── OpenSSL.xcframework                  
│   ├── Debug/
│   │   └── CShieldEmbedded.xcframework            
│   └── Release/
│       └── CShieldEmbedded.xcframework    
├── Flutter/
├── Products/
├── Pods/
├── Framework/
└── ...

```

> **Note:** both `CShieldEmbedded.xcframework` files (Debug/Release) share the
> same name - they're distinguished entirely by the folder they live in.
> No renaming is needed, just copy into the
> right folder.

> **Note:** you must **drag and drop** each `.xcframework` file into the
> matching location in the Xcode Project Navigator:
> - `OpenSSL.xcframework` → drag into the `Libs/` group
> - `CShieldEmbedded.xcframework` (Debug) → drag into the `Libs/Debug/` group
> - `CShieldEmbedded.xcframework` (Release) → drag into the `Libs/Release/` group
>
> If you skip the drag-and-drop step, Xcode won't recognize these frameworks
> in the project.

> **Note:**  If you want to replace the old `.xcrfamework` file by the new one, delete the old file first
> then **drag and drop** the new one.

---

## Step 3 - Update the `Podfile`

Open `ios/Podfile` and add a `post_install` hook to set the Framework Search
Paths for CShieldEmbedded. This must be set in **two places** to cover both
compiling and linking:

```ruby
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)

    # 1. Pod targets - so the c_shield_embedded plugin can compile `import CShieldEmbedded`.
    # Use sdk-conditional paths so the linker picks the correct slice (simulator vs device).
    # DO NOT add both slices to a non-conditional variable: Xcode searches paths in
    # order and will link the wrong ios-arm64 (device binary) when building for the
    # simulator → "Building for iOS-simulator, but linking in dylib built for iOS".
    target.build_configurations.each do |config|
      variant = (config.name == 'Debug') ? 'Debug' : 'Release'

      # Only add the CShieldEmbedded slice to the CONDITIONAL [sdk=...] variables,
      # and make sure to PRESERVE the existing conditional value -
      # flutter_additional_ios_build_settings already sets the Flutter engine path
      # here. Overwriting it would lose the Flutter path ⇒ "Unable to find module
      # 'Flutter'". DO NOT touch the non-conditional FRAMEWORK_SEARCH_PATHS and DO
      # NOT add both slices to the same variable (Xcode searches in order → wrong
      # ios-arm64 device slice gets linked when building for the simulator).
      config.build_settings['FRAMEWORK_SEARCH_PATHS[sdk=iphoneos*]'] = (
        ['$(inherited)'] + Array(config.build_settings['FRAMEWORK_SEARCH_PATHS[sdk=iphoneos*]']).flatten +
        ["\"$(PODS_ROOT)/../Libs/#{variant}/CShieldEmbedded.xcframework/ios-arm64\""]
      ).uniq

      config.build_settings['FRAMEWORK_SEARCH_PATHS[sdk=iphonesimulator*]'] = (
        ['$(inherited)'] + Array(config.build_settings['FRAMEWORK_SEARCH_PATHS[sdk=iphonesimulator*]']).flatten +
        ["\"$(PODS_ROOT)/../Libs/#{variant}/CShieldEmbedded.xcframework/ios-arm64_x86_64-simulator\""]
      ).uniq
    end
  end

  # 2. Aggregate xcconfig (Pods-Runner.debug/release.xcconfig) - use sdk-conditional
  # paths so the linker picks the correct xcframework slice (simulator vs device).
  # Don't use non-conditional FRAMEWORK_SEARCH_PATHS, since Xcode searches paths in
  # order and will link the wrong ios-arm64 (device binary) when building for the
  # simulator.
  installer.aggregate_targets.each do |aggregate_target|
    aggregate_target.xcconfigs.each do |config_name, xcconfig|
      variant = (config_name == 'Debug') ? 'Debug' : 'Release'
      xcconfig_path = aggregate_target.xcconfig_path(config_name).to_s

      xcconfig.save_as(aggregate_target.xcconfig_path(config_name))

      File.open(xcconfig_path, 'a') do |f|
        f.puts "FRAMEWORK_SEARCH_PATHS[sdk=iphonesimulator*] = $(inherited) \"$(PODS_ROOT)/../Libs/#{variant}/CShieldEmbedded.xcframework/ios-arm64_x86_64-simulator\""
        f.puts "FRAMEWORK_SEARCH_PATHS[sdk=iphoneos*] = $(inherited) \"$(PODS_ROOT)/../Libs/#{variant}/CShieldEmbedded.xcframework/ios-arm64\""
      end
    end
  end
end
```

Then run:

```bash
flutter pub get
cd ios && pod install
```

---

## Step 4 - Configure Xcode (manual)

Open `Runner.xcworkspace` in Xcode.

### 4a. Embed OpenSSL (required whenever XCFramework files added or changed/replaced)

`Runner target → General → Frameworks, Libraries, and Embedded Content → +`

Select `Libs/OpenSSL.xcframework` and set the **Embed** column to **Embed & Sign**.

If `CShieldEmbedded.xcframework` shows up here, select it and remove it with the `-` button.

### 4b. Disable User Script Sandboxing

`Runner target → Build Settings → User Script Sandboxing → No`

### 4c. Add a Run Script phase to embed CShieldEmbedded

`Runner target → Build Phases → + → New Run Script Phase`

Name the phase **Embed CShieldEmbedded** and drag it to right below **Compile Sources**.

Paste the following script:

```bash
if [[ "$SDK_NAME" == *"simulator"* ]]; then
  SLICE="ios-arm64_x86_64-simulator"
else
  SLICE="ios-arm64"
fi

# Normalize configuration name to Debug or Release.
# Flutter flavors produce config names like "Debug-production",
# "Release-production", "Profile-production"... which don't match the
# folder names under Libs/.
if [[ "$CONFIGURATION" == *"Release"* ]] || [[ "$CONFIGURATION" == *"Profile"* ]]; then
  LIB_CONFIG="Release"
else
  LIB_CONFIG="Debug"
fi

SRC="${PROJECT_DIR}/Libs/${LIB_CONFIG}/CShieldEmbedded.xcframework/${SLICE}/CShieldEmbedded.framework"
DEST="${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}/CShieldEmbedded.framework"

mkdir -p "${DEST}"
rsync -av --delete "${SRC}/" "${DEST}/"

if [ -n "${EXPANDED_CODE_SIGN_IDENTITY}" ]; then
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" "${DEST}"
fi
```

In the **Output Files** section of this phase, add:

```
$(BUILT_PRODUCTS_DIR)/$(FRAMEWORKS_FOLDER_PATH)/CShieldEmbedded.framework
```

---

## Final result - folder structure

```
<your_app>/ios/
├── Libs/
│   ├── OpenSSL.xcframework
│   ├── Debug/
│   │   └── CShieldEmbedded.xcframework
│   └── Release/
│       └── CShieldEmbedded.xcframework
├── Podfile                    ← updated in Step 3
└── Runner.xcworkspace
```

---

## Summary of what each step does

| Step | What happens | Equivalent native doc step |
|------|---------------|------------------------|
| `s.frameworks = 'CShieldEmbedded'` in the plugin's podspec | CocoaPods automatically writes `-framework CShieldEmbedded` into `Pods-Runner.*.xcconfig` → Runner inherits it | Step 6: Other Linker Flags |
| `post_install` search paths | The compiler and linker can find `CShieldEmbedded.framework` for the right variant | Step 7: Framework Search Paths |
| Embed OpenSSL (Xcode - Step 4a) | `OpenSSL.xcframework` gets packaged into the app bundle | Step 5: Embed & Sign |
| Run Script "Embed CShieldEmbedded" (Xcode - Step 4c) | Copies the right variant (Debug/Release) into the app bundle at build time | Step 9: Run Script Phase |
| Disable User Script Sandboxing (Xcode - Step 4b) | Allows the Run Script to access files outside the sandbox | Step 8: User Script Sandboxing |

---

## Troubleshooting

### Simulator build fails: `linking in dylib built for 'iOS'`

**Symptom**:

```
Error (Xcode): Building for 'iOS-simulator', but linking in dylib
(.../CShieldEmbedded.xcframework/ios-arm64/CShieldEmbedded.framework/CShieldEmbedded) built for 'iOS'
Error (Xcode): Linker command failed with exit code 1
```

**Cause**: When `FRAMEWORK_SEARCH_PATHS` contains both slice paths without a
condition, Xcode searches for `CShieldEmbedded.framework` in list order. If
`ios-arm64` (the device binary) comes before
`ios-arm64_x86_64-simulator`, Xcode links the wrong binary - the one built for
device - even when building for the simulator, bypassing the xcframework's
slice-selection mechanism entirely.

**Fix**: Use the xcconfig conditional syntax `[sdk=...]` in the aggregate
xcconfig section of `post_install` so each SDK only sees its own slice path
(already applied in Step 3 above). After editing the Podfile, run
`pod install` again.

---

### Simulator build fails: `(l)stat: No such file or directory` at `Libs/Debug-production/...`

**Cause**: When the project uses Flutter flavors (e.g. `production`,
`development`), Xcode names the build configuration `Debug-production`,
`Release-production`, `Profile-production`, etc., instead of plain
`Debug`/`Release`. The script in the "Embed CShieldEmbedded" phase used
`${CONFIGURATION}` directly as the folder name, so it looked for
`Libs/Debug-production/`, which doesn't exist.

**Fix**: Add a normalization step in the script before using it as a path
(already applied in the Step 4c script above). If you configured this
manually with an older script, fix it by adding the following before the
`SRC=...` line:

```bash
if [[ "$CONFIGURATION" == *"Release"* ]] || [[ "$CONFIGURATION" == *"Profile"* ]]; then
  LIB_CONFIG="Release"
else
  LIB_CONFIG="Debug"
fi
```

And replace `${CONFIGURATION}` with `${LIB_CONFIG}` in the `SRC=...` line.

---

### `pod install` fails with: `Unable to find compatibility version string for object version 74`

**Cause**: Xcode 16 (some beta/RC versions) saves the project with
`objectVersion = 74`. The xcodeproj gem (used by CocoaPods 1.16.x) only knows
about `60` (Xcode 15.0), `63` (Xcode 15.3), and `77` (Xcode 16.0 final) - it
doesn't recognize `74`.

**Fix**: Open `ios/Runner.xcodeproj/project.pbxproj`, find the line near the
top of the file, and change:

```
objectVersion = 74;
```
to:
```
objectVersion = 77;
```

---

### `pod install` prints a warning: `Xcodeproj doesn't know about the following attributes {"attributesByRelativePath" => ...} for the 'PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet'`

**This is a harmless warning** - it does not cause `pod install` to fail.

**Explanation**: When performing Step 4a (adding `OpenSSL.xcframework` with
"Embed & Sign" in the Xcode UI), Xcode automatically creates a
`PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet` entry in
`project.pbxproj` to store the `CodeSignOnCopy` / `RemoveHeadersOnCopy`
attributes. This entry appears because the `Libs/` folder is managed by Xcode
as a **File System Synchronized Root Group** (an Xcode 15+ feature). The
xcodeproj gem knows about this ISA type but not yet about the
`attributesByRelativePath` attribute inside it, hence the warning.

`pod install` **does not overwrite** `Runner/project.pbxproj`, so the
attribute is preserved - OpenSSL is still embedded correctly with
`CodeSignOnCopy` + `RemoveHeadersOnCopy` when building in Xcode.
