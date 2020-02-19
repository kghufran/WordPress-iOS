import Foundation

struct PostEditorAnalyticsSession {
    private let sessionId = UUID().uuidString
    let postType: String
    let blogType: String
    let contentType: String
    var started = false
    var currentEditor: Editor
    var hasUnsupportedBlocks = false
    var outcome: Outcome? = nil
    var pageTemplateApplied = ""

    init(editor: Editor, post: AbstractPost) {
        currentEditor = editor
        postType = post.analyticsPostType ?? "unsupported"
        blogType = post.blog.analyticsType.rawValue
        contentType = ContentType(post: post).rawValue
    }

    mutating func start(unsupportedBlocks: [String] = []) {
        assert(!started, "An editor session was attempted to start more than once")
        hasUnsupportedBlocks = !unsupportedBlocks.isEmpty

        let properties = startEventProperties(with: unsupportedBlocks)

        WPAppAnalytics.track(.editorSessionStart, withProperties: properties)
        started = true
    }
    
    mutating func editorSessionTemplateApplied(_ appliedTemplate:String) {
        pageTemplateApplied = appliedTemplate
    }

    private func startEventProperties(with unsupportedBlocks: [String]) -> [String: Any] {
        return [
            Property.unsupportedBlocks: unsupportedBlocks
        ].merging(commonProperties, uniquingKeysWith: { $1 })
    }

    mutating func `switch`(editor: Editor) {
        currentEditor = editor
        WPAppAnalytics.track(.editorSessionSwitchEditor, withProperties: commonProperties)
    }

    mutating func forceOutcome(_ newOutcome: Outcome) {
        // We're allowing an outcome to be force in a few specific cases:
        // - If a post was published, that should be the outcome no matter what happens later
        // - If a post is saved, that should be the outcome unless it's published later
        // - Otherwise, we'll use whatever outcome is set when the session ends
        switch (outcome, newOutcome) {
        case (_, .publish), (nil, .save):
            self.outcome = newOutcome
        default:
            break
        }
    }

    func end(outcome endOutcome: Outcome) {
        let outcome = self.outcome ?? endOutcome
        let properties = [
            Property.outcome: outcome.rawValue,
            Property.template: pageTemplateApplied,
            ].merging(commonProperties, uniquingKeysWith: { $1 })

        WPAppAnalytics.track(.editorSessionEnd, withProperties: properties)
    }
}

private extension PostEditorAnalyticsSession {
    enum Property {
        static let blogType = "blog_type"
        static let contentType = "content_type"
        static let editor = "editor"
        static let hasUnsupportedBlocks = "has_unsupported_blocks"
        static let unsupportedBlocks = "unsupported_blocks"
        static let postType = "post_type"
        static let outcome = "outcome"
        static let sessionId = "session_id"
        static let template = "template"
    }

    var commonProperties: [String: String] {
        return [
            Property.editor: currentEditor.rawValue,
            Property.contentType: contentType,
            Property.postType: postType,
            Property.blogType: blogType,
            Property.sessionId: sessionId,
            Property.hasUnsupportedBlocks: hasUnsupportedBlocks ? "1" : "0"
        ]
    }
}

extension PostEditorAnalyticsSession {
    enum Editor: String {
        case gutenberg
        case classic
        case html
    }

    enum ContentType: String {
        case new
        case gutenberg
        case classic

        init(post: AbstractPost) {
            if post.isContentEmpty() {
                self = .new
            } else if post.containsGutenbergBlocks() {
                self = .gutenberg
            } else {
                self = .classic
            }
        }
    }

    enum Outcome: String {
        case cancel
        case discard
        case save
        case publish
    }
}
