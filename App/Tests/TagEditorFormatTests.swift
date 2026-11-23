//
// Vespertine: the tag editor's footer names the kind of tags it writes; an xHE-AAC song (named apart only for network
// players) is an MP4 file like any AAC one.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import Vespertine

@Suite("Tag editor format")
struct TagEditorFormatTests {
    @Test("An xHE-AAC song's tags are MP4 atoms, as an AAC song's")
    func xheAAC() {
        #expect(TagEditorView.tagFormat(codec: "xHE-AAC") == TagEditorView.tagFormat(codec: "AAC"))
        #expect(TagEditorView.tagFormat(codec: "AAC") != TagEditorView.tagFormat(codec: "unknown"))
    }
}
