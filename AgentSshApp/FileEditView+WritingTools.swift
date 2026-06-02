import SwiftUI
import AppIntents

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A localized coordinator manager that hooks custom text and log viewer elements
/// directly to native iOS 18 / macOS Sequoia Writing Tools delegations.
@available(iOS 18.2, macOS 15.2, *)
public class ServerDoctorWritingToolsManager: NSObject {
    public static let shared = ServerDoctorWritingToolsManager()
    
    // Backing store mapping active selection ranges to attributed strings
    private var textStorageMap: [String: NSAttributedString] = [:]
    
    private override init() {
        super.init()
    }
    
    public func registerTextSelection(id: String, content: NSAttributedString) {
        textStorageMap[id] = content
    }
    
    public func clearTextSelection(id: String) {
        textStorageMap.removeValue(forKey: id)
    }
}

// MARK: - iOS / iPadOS Delegate Implementation
#if canImport(UIKit)
@available(iOS 18.2, *)
extension ServerDoctorWritingToolsManager: UIWritingToolsCoordinator.Delegate {
    public func writingToolsCoordinator(
        _ coordinator: UIWritingToolsCoordinator,
        requestsContextsFor scope: UIWritingToolsCoordinator.ContextScope,
        completion: @escaping ([UIWritingToolsCoordinator.Context]) -> Void
    ) {
        let content = textStorageMap.values.first ?? NSAttributedString()
        let context = UIWritingToolsCoordinator.Context(attributedString: content, range: NSRange(location: 0, length: content.length))
        completion([context])
    }
    
    public func writingToolsCoordinator(
        _ coordinator: UIWritingToolsCoordinator,
        replace range: NSRange,
        in context: UIWritingToolsCoordinator.Context,
        proposedText: NSAttributedString,
        reason: UIWritingToolsCoordinator.TextReplacementReason,
        animationParameters: UIWritingToolsCoordinator.AnimationParameters?,
        completion: @escaping (NSAttributedString?) -> Void
    ) {
        completion(proposedText)
    }
    
    public func writingToolsCoordinator(
        _ coordinator: UIWritingToolsCoordinator,
        select ranges: [NSValue],
        in context: UIWritingToolsCoordinator.Context
    ) async {
        // No-op or update selection
    }
    
    public func writingToolsCoordinator(
        _ coordinator: UIWritingToolsCoordinator,
        boundingBezierPathsFor range: NSRange,
        context: UIWritingToolsCoordinator.Context
    ) async -> [UIBezierPath] {
        return []
    }
    
    public func writingToolsCoordinator(
        _ coordinator: UIWritingToolsCoordinator,
        underlinePathsFor range: NSRange,
        context: UIWritingToolsCoordinator.Context
    ) async -> [UIBezierPath] {
        return []
    }
    
    public func writingToolsCoordinator(
        _ coordinator: UIWritingToolsCoordinator,
        prepareFor textAnimation: UIWritingToolsCoordinator.TextAnimation,
        for range: NSRange,
        in context: UIWritingToolsCoordinator.Context
    ) async {
        // No-op
    }
    
    public func writingToolsCoordinator(
        _ coordinator: UIWritingToolsCoordinator,
        previewFor textAnimation: UIWritingToolsCoordinator.TextAnimation,
        range: NSRange,
        context: UIWritingToolsCoordinator.Context
    ) async -> [UITextPreview]? {
        return nil
    }
    
    public func writingToolsCoordinator(
        _ coordinator: UIWritingToolsCoordinator,
        previewFor rect: CGRect,
        context: UIWritingToolsCoordinator.Context
    ) async -> UITextPreview? {
        return nil
    }
    
    public func writingToolsCoordinator(
        _ coordinator: UIWritingToolsCoordinator,
        finish textAnimation: UIWritingToolsCoordinator.TextAnimation,
        for range: NSRange,
        in context: UIWritingToolsCoordinator.Context
    ) async {
        // No-op
    }
}
#endif

// MARK: - macOS Delegate Implementation
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
@available(macOS 15.2, *)
extension ServerDoctorWritingToolsManager: NSWritingToolsCoordinator.Delegate {
    public func writingToolsCoordinator(
        _ coordinator: NSWritingToolsCoordinator,
        requestsContextsFor scope: NSWritingToolsCoordinator.ContextScope,
        completion: @escaping ([NSWritingToolsCoordinator.Context]) -> Void
    ) {
        let content = textStorageMap.values.first ?? NSAttributedString()
        let context = NSWritingToolsCoordinator.Context(attributedString: content, range: NSRange(location: 0, length: content.length))
        completion([context])
    }
    
    public func writingToolsCoordinator(
        _ coordinator: NSWritingToolsCoordinator,
        replace range: NSRange,
        in context: NSWritingToolsCoordinator.Context,
        proposedText: NSAttributedString,
        reason: NSWritingToolsCoordinator.TextReplacementReason,
        animationParameters: NSWritingToolsCoordinator.AnimationParameters?,
        completion: @escaping (NSAttributedString?) -> Void
    ) {
        completion(proposedText)
    }
    
    public func writingToolsCoordinator(
        _ coordinator: NSWritingToolsCoordinator,
        select ranges: [NSValue],
        in context: NSWritingToolsCoordinator.Context
    ) async {
        // No-op or update selection
    }
    
    public func writingToolsCoordinator(
        _ coordinator: NSWritingToolsCoordinator,
        boundingBezierPathsFor range: NSRange,
        context: NSWritingToolsCoordinator.Context
    ) async -> [NSBezierPath] {
        return []
    }
    
    public func writingToolsCoordinator(
        _ coordinator: NSWritingToolsCoordinator,
        underlinePathsFor range: NSRange,
        context: NSWritingToolsCoordinator.Context
    ) async -> [NSBezierPath] {
        return []
    }
    
    public func writingToolsCoordinator(
        _ coordinator: NSWritingToolsCoordinator,
        prepareFor textAnimation: NSWritingToolsCoordinator.TextAnimation,
        for range: NSRange,
        in context: NSWritingToolsCoordinator.Context
    ) async {
        // No-op
    }
    
    public func writingToolsCoordinator(
        _ coordinator: NSWritingToolsCoordinator,
        previewFor textAnimation: NSWritingToolsCoordinator.TextAnimation,
        range: NSRange,
        context: NSWritingToolsCoordinator.Context
    ) async -> [NSTextPreview]? {
        return nil
    }
    
    public func writingToolsCoordinator(
        _ coordinator: NSWritingToolsCoordinator,
        previewFor rect: NSRect,
        context: NSWritingToolsCoordinator.Context
    ) async -> NSTextPreview? {
        return nil
    }
    
    public func writingToolsCoordinator(
        _ coordinator: NSWritingToolsCoordinator,
        finish textAnimation: NSWritingToolsCoordinator.TextAnimation,
        for range: NSRange,
        in context: NSWritingToolsCoordinator.Context
    ) async {
        // No-op
    }
}
#endif
