//
//  TagTabViewModel.swift
//  PDFArchiver
//
//  Created by Julian Kahnert on 02.11.19.
//  Copyright © 2019 Julian Kahnert. All rights reserved.
//
// swiftlint:disable force_unwrapping function_body_length cyclomatic_complexity

import Combine
import PDFKit
import SwiftUI

final class TagTabViewModel: ObservableObject, Log {

    // set this property manually
    @Published var documents = [Document]()
    @Published var currentDocument: Document?

    @Published var showLoadingView = true

    // there properties will be set be some combine actions
    @Published var pdfDocument = PDFDocument()
    @Published var date = Date()
    @Published var specification = ""
    @Published var documentTags = [String]()
    @Published var documentTagInput = ""
    @Published var suggestedTags = [String]()

    var taggedUntaggedDocuments: String {
        let filteredDocuments = documents.filter { $0.taggingStatus == .tagged }
        return "\(filteredDocuments.count) / \(documents.count)"
    }

    private let archiveStore: ArchiveStore
    private let tagStore: TagStore
    private var disposables = Set<AnyCancellable>()

    init(archiveStore: ArchiveStore = ArchiveStore.shared, tagStore: TagStore = TagStore.shared) {
        self.archiveStore = archiveStore
        self.tagStore = tagStore

        // MARK: - Combine Stuff
        archiveStore.$state
            .map { state in
                state == .uninitialized
            }
            .receive(on: DispatchQueue.main)
            .assign(to: \.showLoadingView, on: self)
            .store(in: &disposables)

        $documentTags
            .removeDuplicates()
            .combineLatest($documentTagInput)
            .map { (documentTags, tag) -> [String] in
                let tagName = tag.trimmingCharacters(in: .whitespacesAndNewlines).slugified().lowercased()
                let tags: Set<String>
                if tagName.isEmpty {
                    tags = self.getAssociatedTags(from: documentTags)
                } else {
                    tags = self.tagStore.getAvailableTags(with: [tagName])
                }

                let sortedTags = tags
                    .subtracting(Set(self.documentTags))
                    .subtracting(Set([Constants.documentTagPlaceholder]))
                    .sorted { lhs, rhs in
                        if lhs.starts(with: tagName) {
                            if rhs.starts(with: tagName) {
                                return lhs < rhs
                            } else {
                                return true
                            }
                        } else {
                            if rhs.starts(with: tagName) {
                                return false
                            } else {
                                return lhs < rhs
                            }
                        }
                    }
                return Array(sortedTags.prefix(10))
            }
            .assign(to: &$suggestedTags)

        archiveStore.$documents
            // we have to removeDuplicates before filtering, because if we want to trigger
            // the selection of a new document even if we edit a already tagged document
            .removeDuplicates()
            .map { newDocuments -> [Document] in
                newDocuments.filter { $0.taggingStatus == .untagged }
            }
            .compactMap { newUntaggedDocuments -> [Document] in

                let sortedDocuments = newUntaggedDocuments
                    .sorted { doc1, doc2 in

                        // sort by file creation date to get most recent scans at first
                        if let date1 = try? archiveStore.getCreationDate(of: doc1.path),
                           let date2 = try? archiveStore.getCreationDate(of: doc2.path) {

                            return date1 > date2
                        } else {
                            return doc1 > doc2
                        }
                    }
                    .reversed()

                // tagged documents should be first in the list
                var currentDocuments = self.documents.filter { $0.taggingStatus == .tagged }
                    .sorted()
                currentDocuments.append(contentsOf: sortedDocuments)
                DispatchQueue.main.async {
                    self.documents = currentDocuments
                }

                // download new documents
                newUntaggedDocuments
                    .filter { $0.downloadStatus == .remote }
                    .forEach { document in
                        do {
                            try archiveStore.download(document)
                        } catch {
                            NotificationCenter.default.postAlert(error)
                        }
                    }

                return currentDocuments
            }
            .receive(on: DispatchQueue.main)
            .sink { currentDocuments in
                if let currentDocument = self.currentDocument,
                   currentDocument.taggingStatus == .untagged,
                   currentDocuments.contains(currentDocument) {
                    // we should not change anything, if a current document was found
                    // and is not tagged yet
                    // and is part of all currentDocuments
                    return
                }
                self.currentDocument = currentDocuments
                    .first { $0.taggingStatus == .untagged && $0.downloadStatus == .local }
            }
            .store(in: &disposables)

        $currentDocument
            .compactMap { $0 }
            .removeDuplicates()
            .dropFirst()
            .sink { _ in
                FeedbackGenerator.selectionChanged()
            }
            .store(in: &disposables)

        $currentDocument
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { document in
                if let document = document,
                   let pdfDocument = PDFDocument(url: document.path) {
                    self.pdfDocument = pdfDocument

                    // try to parse suggestions from document content
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in

                        // get tags and save them in the background, they will be passed to the TagTabView
                        guard let text = pdfDocument.string else { return }
                        let tags = TagParser.parse(text)
                            .subtracting(Set(self?.documentTags ?? []))
                            .sorted()
                        DispatchQueue.main.async {
                            self?.suggestedTags = Array(tags.prefix(12))
                        }

                        // parse date from document content
                        let documentDate: Date
                        if let date = document.date {
                            documentDate = date
                        } else if let output = DateParser.parse(text) {
                            documentDate = output.date
                        } else {
                            documentDate = Date()
                        }
                        DispatchQueue.main.async {
                            self?.date = documentDate
                        }
                    }

                    self.specification = document.specification
                    self.documentTags = document.tags.sorted()
                    self.suggestedTags = []

                } else {
                    Self.log.error("Could not present document.")
                    self.pdfDocument = PDFDocument()
                    self.specification = ""
                    self.documentTags = []
                    self.suggestedTags = []
                }
            }
            .store(in: &disposables)

        $documentTags
            .removeDuplicates()
            .map { tags -> [String] in
                let tmpTags = tags.map { $0.lowercased().slugified(withSeparator: "") }
                    .filter { !$0.isEmpty }

                FeedbackGenerator.selectionChanged()

                return Set(tmpTags).sorted()
            }
            .receive(on: DispatchQueue.main)
            .assign(to: &$documentTags)
    }

    func saveTag(_ tagName: String) {
        // reset this value after the documents have been set, because the input view
        // tags will be triggered by this and depend on the document tags
        defer {
            documentTagInput = ""
        }

        let input = tagName.lowercased().slugified(withSeparator: "")
        guard !input.isEmpty else { return }
        var tags = Set(documentTags)
        tags.insert(input)
        documentTags = Array(tags).sorted()
    }

    func saveDocument() {
        guard let document = currentDocument else { return }

        // slugify the specification first to fix this bug:
        // View was not updating, when the document is already tagged:
        // * save document
        // * change specification
        specification = specification.slugified(withSeparator: "-").lowercased()

        document.date = date
        document.specification = specification
        document.tags = Set(documentTags.map { $0.slugified(withSeparator: "") })

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.archiveStore.archive(document, slugify: true)
                var filteredDocuments = self.archiveStore.documents.filter { $0.id != document.id }
                filteredDocuments.append(document)
                // this will trigger the publisher, which calls getNewDocument, e.g.
                // updates the current document
                self.archiveStore.documents = filteredDocuments

                FeedbackGenerator.notify(.success)

                // increment the AppStoreReview counter
                AppStoreReviewRequest.shared.incrementCount()

            } catch {
                Self.log.error("Error in PDFProcessing!", metadata: ["error": "\(error)"])
                NotificationCenter.default.postAlert(error)

                FeedbackGenerator.notify(.error)
            }
        }
    }

    func deleteDocument() {

        FeedbackGenerator.notify(.success)

        // delete document in archive
        guard let currentDocument = currentDocument else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // this will trigger the publisher, which calls getNewDocument, e.g.
                // updates the current document
                try self.archiveStore.delete(currentDocument)

                DispatchQueue.main.async {
                    // delete document from document list - immediately
                    self.documents.removeAll { $0.filename == currentDocument.filename }
                }
            } catch {
                Self.log.error("Error while deleting document!", metadata: ["error": "\(error)"])
                NotificationCenter.default.postAlert(error)
            }
        }
    }

    private func getAssociatedTags(from documentTags: [String]) -> Set<String> {
        guard let firstDocumentTag = documentTags.first?.lowercased() else { return [] }
        var tags = tagStore.getSimilarTags(for: firstDocumentTag)
        for documentTag in documentTags.dropFirst() {

            // enforce that tags is not empty, because all intersection will be also empty otherwise
            guard !tags.isEmpty else { break }

            tags.formIntersection(tagStore.getSimilarTags(for: documentTag.lowercased()))
        }
        return tags
    }
}
