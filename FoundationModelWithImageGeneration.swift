//
//  FM+ImagePlayground.swift
//  iOSDemo1
//
//  Created by Itsuki on 2025/10/04.
//

import SwiftUI
import FoundationModels
import ImagePlayground
import QuickLook

@Generable
private struct GeneratedImages {
    @Guide(description: "A list of url for the generated images")
    var images: [String]
}

@Generable
private struct ResponseType {
    @Guide(description: "A list of urls for the generated binaries. Empty if no binaries generated.")
    var urls: [String]
    
    @Guide(description: "Text response.")
    var textResponse: String
}

private extension NSImage {
    nonisolated
    var data: Data? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = self.size
        return rep.representation(using: .png, properties: [:])
    }
}


private extension URL {
    nonisolated
    var absolutePath: String {
        return self.path(percentEncoded: false)
    }
    
    static func resolvedPathURL(string: String) -> URL? {
        guard let url = URL(string: string) else {
            return nil
        }
        
        if url.isFileURL {
            return url
        }
        
        return URL(filePath: string)
    }
    
}

private extension CGImage {

    nonisolated
    var nsImage: NSImage {
        NSImage(cgImage: self, size: .init(width: CGFloat(self.width), height: CGFloat(self.height)))
    }
}

private extension ImagePlaygroundStyle {
    nonisolated
    init?(id: String) {
        switch id {
        case ImagePlaygroundStyle.animation.id:
            self = .animation
        case ImagePlaygroundStyle.illustration.id:
            self = .illustration
        case ImagePlaygroundStyle.sketch.id:
            self = .sketch
        default:
            return nil
        }
    }
}


private struct GenerateImageTool: Tool {
        
    private let creator: ImageCreator
    
    init(creator: ImageCreator) {
        self.creator = creator
    }
    
    let name = "GenerateImage"
    let description = "Generate images when requested by the user."
    
    private let tempDirectory = FileManager.default.temporaryDirectory

    @Generable
    struct Arguments {
        @Guide(description: "Text describing the expected contents of the image.")
        let content: String
        
        // have to use id, ie: String here, because ImagePlaygroundStyle cannot be used as Guided type
        @Guide(description: "Style for image generation. Available ones: \(ImagePlaygroundStyle.animation.id), \(ImagePlaygroundStyle.illustration.id), \(ImagePlaygroundStyle.sketch.id)")
        let style: String
        
        @Guide(description: "Number of images to generate.")
        let limit: Int

    }

    func call(arguments: Arguments) async throws -> GeneratedImages {
        var count = 0
        var urls:[URL] = []

        let style = ImagePlaygroundStyle(id: arguments.style) ?? .illustration

        let images = creator.images(
            for: [.text(arguments.content)],
            style: style,
            limit: arguments.limit
        )
        
        for try await image in images {
            if let data = image.cgImage.nsImage.data {
                let url = tempDirectory.appending(path: "\(UUID()).png")
                try data.write(to: url)
                urls.append(url)
            }
            
            count = count + 1
            if count >= arguments.limit {
                break
            }
        }

        return GeneratedImages(images: urls.map({$0.absolutePath}))
    }
}


@Observable
private class ChatManager {
        
    private(set) var messages: [MessageType] = []
    
    var isResponding: Bool {
        self.session?.isResponding ?? false
    }
    
    var generatedBinaries: [URL] {
        var urls: [URL] = []
        
        for message in messages {
            if case .response(_, let response) = message {
                let urlStrings = response.urls
                let urlsTemp = urlStrings.map({URL.resolvedPathURL(string: $0)}).filter({$0 != nil}).map({$0!})
                urls.append(contentsOf: urlsTemp)
            }
        }
        
        return urls
    }

    var error: (any Error)? = nil {
        didSet {
            if let error = error {
                print(error)
            }
        }
    }
    
    enum _Error: Error {
        case modelUnavailable(String)
        case initializationFailed
        
        var message: String {
            switch self {
            case .modelUnavailable(let string):
                return string
            case .initializationFailed:
                return "initialization failed"
            }
        }
    }
    
    enum MessageType: Identifiable, Equatable {
        case userPrompt(UUID, String)
        case response(UUID, ResponseType)
        
        var id: UUID {
            switch self {
            case .userPrompt(let id, _):
                return id
            case .response(let id, _):
                return id
            }
        }
        
        static func == (lhs: Self, rhs: Self) -> Bool {
            return lhs.id == rhs.id
        }
    }
    
    private var generateImageTool: GenerateImageTool?
   
    private var session: LanguageModelSession?
    
    private let model = SystemLanguageModel.default
    
    init() {
        
        Task {
            do {
                try self.checkAvailability()
                let imageCreator = try await ImageCreator()
                let tool = GenerateImageTool(creator: imageCreator)
                self.generateImageTool = tool
                self.session = .init(
                    model: self.model,
                    tools: [tool],
                    instructions: Instructions {
                        "You are a helpful assistant."
                        "Your job is to fulfill user's requests."
                        """
                        You have access to the following tools.
                        - \(tool.name): \(tool.description)
                        
                        You should strictly follow the given rules:
                        - You should only use tools if necessary.
                        """
                    }
                )
            } catch (let error) {
                self.error = error
            }
        }
    }

    func respond(to prompt: String) async throws {
        print(#function)
        print(prompt)
        guard let session else {
            throw _Error.initializationFailed
        }
        if session.isResponding {
            return
        }
        self.messages.append(.userPrompt(UUID(), prompt))
        let response = try await session.respond(to: prompt, generating: ResponseType.self)
        self.messages.append(.response(UUID(), response.content))
    }
    
    
    private func checkAvailability() throws {
        let availability = model.availability
        if case .unavailable(let reason) = availability {
            switch reason {
            case .appleIntelligenceNotEnabled:
                throw _Error.modelUnavailable("Apple Intelligence is not enabled.")
            case .deviceNotEligible:
                throw _Error.modelUnavailable("This device is not eligible.")
            case .modelNotReady:
                throw  _Error.modelUnavailable("Model is not ready.")
            @unknown default:
                throw _Error.modelUnavailable("Unknown reason.")
            }
        }
    }

}



struct FoundationModelWithImageGeneration: View {
    @State private var chatManager: ChatManager = .init()
    @State private var showSettingPopup: Bool = true
    @State private var entry: String = ""
    @State private var scrollPosition: ScrollPosition = .init()
    
    @State private var selectedURL: URL?
    @State private var entryHeight: CGFloat = 24

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Text("FoundationModel + ImageGeneration")
                    .font(.title2)
                    .fontWeight(.bold)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.white)
                
                if let error = chatManager.error {
                    Text(String("\(error)"))
                        .foregroundStyle(.red)
                        .listRowSeparator(.hidden)

                }
                
                ForEach(chatManager.messages) { message in
                    let isUser: Bool = if case .userPrompt(_, _) = message {
                        true
                    } else {
                        false
                    }
                    
                    Group {
                        switch message {
                        case .response(_, let response):
                            VStack(alignment: .leading) {
                                Text(response.textResponse)
                                
                                if !response.urls.isEmpty {
                                    Divider()
                                        .padding(.vertical, 8)
                                    Text("URL for the Generated Contents")
                                        .font(.headline)
                                    
                                    ForEach(0..<response.urls.count, id:\.self) { index in
                                        let urlString: String = response.urls[index]
                                        if let url = URL.resolvedPathURL(string: urlString) {
                                            Button(action: {
                                                selectedURL = url
                                            }, label: {
                                                Text(url.lastPathComponent.isEmpty ? urlString : url.lastPathComponent )
                                            })
                                            .quickLookPreview($selectedURL, in: self.chatManager.generatedBinaries)
                                        }
                                    }
                                }

                            }
                            .listRowBackground(Color.clear)

                        case .userPrompt(_, let prompt):
                            Text(prompt)
                                .listRowBackground(Color.clear)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.all, 16)
                    .background(RoundedRectangle(cornerRadius: 24).fill(isUser ? .yellow : .green))
                    .padding(isUser ? .leading: .trailing, 64)
                    .listRowInsets(.all, 0)
                    .padding(.vertical, 16)
                    .listRowSeparator(.hidden)

                }
            }
            .foregroundStyle(.black)
            .font(.headline)
            .scrollTargetLayout()
            .frame(maxWidth: .infinity)
            .scrollPosition($scrollPosition, anchor: .bottom)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onChange(of: self.chatManager.messages, initial: true, {
                if let last = chatManager.messages.last {
                    proxy.scrollTo(last.id)
                }
            })
        }
        .frame(minWidth: 480, minHeight: 400)
        .padding(.bottom, self.entryHeight)
        .overlay(alignment: .bottom, content: {
            HStack(spacing: 12) {
                TextEditor(text: $entry)
                    .onSubmit({
                        self.sendPrompt()
                    })
                    .textEditorStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundStyle(.background.opacity(0.8))
                    .padding(.all, 4)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .stroke(.gray, style: .init(lineWidth: 1))
                        .fill(.white)
                    )
                    .frame(maxHeight: 120)
                    .fixedSize(horizontal: false, vertical: true)
                
                Button(action: {
                    self.sendPrompt()
                }, label: {
                    Image(systemName: "paperplane.fill")
                })
                .buttonStyle(.glass)
                .foregroundStyle(.blue)
                .disabled(self.chatManager.isResponding)
                
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 24)
            .background(.yellow.opacity(0.2))
            .background(.white)
            .onGeometryChange(for: CGFloat.self, of: {
                $0.size.height
            }, action: { old, new in
                self.entryHeight = new
            })
            
        })
    }
    
    private func sendPrompt() {
        let entry = self.entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        guard !chatManager.isResponding else {
            return
        }
        
        self.entry = ""

        Task {
            do {
                try await self.chatManager.respond(to: entry)
            } catch(let error) {
                self.chatManager.error = error
            }
        }

    }

}


#Preview(body: {
    FoundationModelWithImageGeneration()
})
