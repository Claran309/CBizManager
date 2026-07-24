# CBizDocsManager Full Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the repository, Flutter application, platform identifiers, documentation titles, and planned backend/API identity from ProjectF/client defaults to CBizDocsManager.

**Architecture:** Use `CBizDocsManager` as the human-facing product and repository name. Use platform-valid forms where required: `c_biz_docs_manager` for the Dart package, `com.claran.cbizdocsmanager` for Android, and `cbizdocsmanager-v1.yaml` for the planned OpenAPI file.

**Tech Stack:** Git, Dart, Flutter, Android Gradle/Kotlin, Windows CMake/Win32 resources, Flutter Web, Markdown, PowerShell

---

### Task 1: Capture the pre-rename state

**Files:**
- Inspect: `client/pubspec.yaml`
- Inspect: `client/android/app/build.gradle.kts`
- Inspect: `client/windows/CMakeLists.txt`
- Inspect: `client/web/manifest.json`
- Inspect: `docs/output/*.md`

- [ ] **Step 1: Confirm the old identifiers are present**

Run:

```powershell
rg -n --hidden -g '!.git/**' -g '!client/.dart_tool/**' -g '!client/build/**' 'ProjectF|name:\s*client|com\.example\.client|Flutter Demo' .
```

Expected: matches appear in the Flutter project and project documentation.

- [ ] **Step 2: Record existing user changes**

Run:

```powershell
git diff -- client/README.md
git status --short
```

Expected: the existing `CBizManager的客户端，采用flutter搭建` description remains visible and must be preserved while correcting the name.

### Task 2: Rename the Flutter package and visible application

**Files:**
- Modify: `client/pubspec.yaml`
- Modify: `client/README.md`
- Modify: `client/lib/main.dart`
- Modify: `client/test/widget_test.dart`
- Modify: `client/web/index.html`
- Modify: `client/web/manifest.json`

- [ ] **Step 1: Apply the Flutter and Web names**

Set the Dart package to `c_biz_docs_manager`, use `CBizDocsManager` for visible titles, and preserve the user's Chinese client description.

- [ ] **Step 2: Update the widget test import**

Replace `package:client/main.dart` with `package:c_biz_docs_manager/main.dart`.

### Task 3: Rename Android and Windows platform identifiers

**Files:**
- Modify: `client/android/app/build.gradle.kts`
- Modify: `client/android/app/src/main/AndroidManifest.xml`
- Delete: `client/android/app/src/main/kotlin/com/example/client/MainActivity.kt`
- Create: `client/android/app/src/main/kotlin/com/claran/cbizdocsmanager/MainActivity.kt`
- Modify: `client/windows/CMakeLists.txt`
- Modify: `client/windows/runner/main.cpp`
- Modify: `client/windows/runner/Runner.rc`

- [ ] **Step 1: Apply the Android identity**

Use namespace and application ID `com.claran.cbizdocsmanager`, application label `CBizDocsManager`, and Kotlin package `com.claran.cbizdocsmanager`.

- [ ] **Step 2: Apply the Windows identity**

Use project/binary/window/product name `CBizDocsManager` and executable name `CBizDocsManager.exe`.

### Task 4: Rename documentation and planned backend/API identity

**Files:**
- Modify: `README.md`
- Modify: `docs/output/README.md`
- Modify: `docs/output/需求.md`
- Modify: `docs/output/技术设计.md`
- Modify: `docs/output/开发计划.md`
- Modify: `docs/output/测试验收.md`
- Modify: `docs/superpowers/specs/2026-07-23-backend-foundation-auth-design.md`

- [ ] **Step 1: Replace product titles**

Replace `ProjectF` with `CBizDocsManager` in project-owned documentation.

- [ ] **Step 2: Update planned backend/API names**

Use Go module name `CBizDocsManager/backend` and planned OpenAPI filename `api/openapi/cbizdocsmanager-v1.yaml`.

### Task 5: Verify Flutter code and all three builds

**Files:**
- Verify: `client/`

- [ ] **Step 1: Confirm no stale product identifiers remain**

Run:

```powershell
rg -n --hidden -g '!.git/**' -g '!client/.dart_tool/**' -g '!client/build/**' 'ProjectF|name:\s*client|com\.example\.client|Flutter Demo|CBizManager' .
```

Expected: no matches in active project files.

- [ ] **Step 2: Refresh dependencies and run checks**

Run from `client/`:

```powershell
flutter clean
flutter pub get
flutter analyze
flutter test
```

Expected: dependency resolution succeeds, analysis reports no issues, and tests pass.

- [ ] **Step 3: Build all delivery platforms**

Run from `client/`:

```powershell
flutter build web
flutter build windows
flutter build apk --debug
```

Expected: all three commands exit successfully and produce Web, Windows, and Android build artifacts.

### Task 6: Rename the repository directory and perform final checks

**Files:**
- Move: `D:\CodeStudy\ProjectF` to `D:\CodeStudy\CBizDocsManager`

- [ ] **Step 1: Verify the destination is safe**

Confirm `D:\CodeStudy\ProjectF` exists and `D:\CodeStudy\CBizDocsManager` does not exist.

- [ ] **Step 2: Rename from the parent directory**

Run with working directory `D:\CodeStudy`:

```powershell
Move-Item -LiteralPath 'D:\CodeStudy\ProjectF' -Destination 'D:\CodeStudy\CBizDocsManager'
```

- [ ] **Step 3: Verify the renamed workspace**

Run from `D:\CodeStudy\CBizDocsManager`:

```powershell
git rev-parse --show-toplevel
git status --short
rg -n --hidden -g '!.git/**' -g '!client/.dart_tool/**' -g '!client/build/**' 'ProjectF|com\.example\.client|Flutter Demo|CBizManager' .
```

Expected: Git reports the new root path and the stale-name search returns no active project matches.
