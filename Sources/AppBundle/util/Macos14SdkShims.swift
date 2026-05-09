// Sendable conformance shims for AppKit types missing them in the macOS 14 SDK.
//
// Background: AeroSpace's Package.swift declares Swift 6.2 with strict
// concurrency. Apple added `@Sendable` annotations to several AppKit types
// in the macOS 15 SDK, including NSRunningApplication. The macOS 14 SDK
// (shipped with Xcode 15.x) lacks them, so any `@Sendable` closure that
// captures e.g. `nsApp: NSRunningApplication` fails to compile with:
//
//   error: capture of 'nsApp' with non-Sendable type 'NSRunningApplication'
//          in a '@Sendable' closure  [#SendableClosureCaptures]
//
// This file declares the missing conformances locally so `mur` builds
// against either SDK. `@retroactive` quiets the warning about adding
// conformance to a type from a different module. `@unchecked` is
// appropriate because we're trusting AppKit's documented thread-safety
// guarantees, the same trust Apple applied in the macOS 15 SDK.
//
// Drop this file once the project's minimum Xcode version is bumped to
// one that ships the macOS 15 SDK or newer.

import AppKit

extension NSRunningApplication: @retroactive @unchecked Sendable {}
