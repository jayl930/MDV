//
//  ContentView.swift
//  MDV
//
//  Created by Jay Lee on 3/29/26.
//

import SwiftUI

struct ContentView: View {
    @Binding var document: MarkdownDocument

    var body: some View {
        MarkdownEditorView(document: $document)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
