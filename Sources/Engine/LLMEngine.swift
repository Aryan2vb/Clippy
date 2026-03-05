import Foundation
import ClippyCore
import os.log

public enum LLMProvider: String, Codable, CaseIterable {
    case ollama = "ollama"
    case groq = "groq"
    
    public var displayName: String {
        switch self {
        case .ollama: return "Ollama (Local)"
        case .groq: return "Groq (Cloud)"
        }
    }
}

public class LLMEngine: @unchecked Sendable {
    private let ollamaURL = URL(string: "http://localhost:11434/api/generate")!
    private let groqURL = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    
    public var selectedModel: String = "llama3.2:3b"
    public var selectedProvider: LLMProvider = .ollama
    public var groqAPIKey: String = ""
    
    private let logger = Logger(subsystem: "Clippy", category: "LLMEngine")
    
    public init() {}
    
    // Check if Ollama is running
    public func isOllamaAvailable() async -> Bool {
        guard selectedProvider == .ollama else { return false }
        
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/tags")!)
        request.timeoutInterval = 2.0
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                return true
            }
        } catch {
            return false
        }
        return false
    }
    
    // Check if Groq is available (API key configured)
    public func isGroqAvailable() async -> Bool {
        guard selectedProvider == .groq else { return false }
        guard !groqAPIKey.isEmpty else { return false }
        return true
    }
    
    // Get available models for Groq
    public func getGroqModels() -> [String] {
        return [
            "openai/gpt-oss-120b",
            "llama-3.3-70b-versatile",
            "llama-3.1-70b-versatile", 
            "llama-3.1-8b-instant",
            "llama-3.2-1b-preview",
            "llama-3.2-3b-preview",
            "llama-3.2-11b-vision-preview",
            "mixtral-8x7b-32768",
            "gemma2-9b-it"
        ]
    }
    
    // Check availability based on current provider
    public func isAvailable() async -> Bool {
        switch selectedProvider {
        case .ollama:
            return await isOllamaAvailable()
        case .groq:
            return await isGroqAvailable()
        }
    }
    
    // Generate suggestions from folder tree
    public func generateSuggestions(folderTree: FolderTreeSummary) async throws -> [LLMSuggestion] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        
        // Filter out directories so the model only sees files
        let filesOnlySummary = FolderTreeSummary(
            rootPath: folderTree.rootPath,
            totalFiles: folderTree.totalFiles,
            totalSizeBytes: folderTree.totalSizeBytes,
            topLevelItems: folderTree.topLevelItems.filter { !$0.isDirectory }
        )
        
        let treeJSONData = try encoder.encode(filesOnlySummary)
        let treeSTR = String(data: treeJSONData, encoding: .utf8) ?? ""
        print(folderTree)
        print(String(repeating: "=", count: 20))

        print("treeJsonData",treeJSONData )
        print(String(repeating: "=", count: 20))
        print(treeSTR)
        print(String(repeating: "=", count: 20))
        
        // let prompt = """
        // Analyze the folder structure below and return a JSON array of file organization suggestions.

        // STRICT JSON FORMAT - you MUST follow this exactly:
        // [{"type":"groupOrphanFiles","description":"Short description","affectedPaths":["/full/path1","/full/path2"],"suggestedAction":"Move to Folder/","confidence":0.85}]

        // Suggestion Types to consider:
        // - "groupByExtension": Group files by their file extension (e.g., all .zip files → zip/ folder)
        // - "groupByNamePattern": Group files by similar names (e.g., Screenshot*.png → Screenshots/)
        // - "groupOrphanFiles": Group loose files in the root that don't belong there
        // - "potentialVersions": Group files that might be versioned (e.g., file.txt, file_v1.txt, file_v2.txt)

        // MANDATORY: You MUST return MULTIPLE suggestions — one per logical file group.
        // NEVER put all files into a single suggestion.
        // Minimum 2 suggestions if there are 5+ files. Minimum 3 if there are 10+ files.
        // Each suggestion must cover a DISTINCT group (by extension, by name pattern, or true orphans).

        // GROUPING PRIORITY — check in this order:
        // 1. Files sharing the same extension → groupByExtension (e.g., all .pdf, all .png, all .zip)
        // 2. Files sharing a name prefix → groupByNamePattern (e.g., "Screenshot *", "Invoice_2024_*")
        // 3. Files sharing a theme → groupByNamePattern (e.g., "ajay.jpeg + teaser1.gif" → 'media')
        // 4. Only remaining files with no pattern → groupOrphanFiles

        // WRONG - do NOT do this: putting all files into one groupOrphanFiles suggestion
        // RIGHT - always split by extension and pattern first, orphans last

        // Example of CORRECT output for files: ["file1.pdf", "file2.pdf", "img1.png", "img2.png", "doc.txt"]
        // RIGHT:
        // [
        //   {"type":"groupByExtension","description":"Group PDF documents","affectedPaths":["file1.pdf","file2.pdf"],"suggestedAction":"Create 'pdfs' folder and move files here","confidence":0.93},
        //   {"type":"groupByExtension","description":"Group image files","affectedPaths":["img1.png","img2.png"],"suggestedAction":"Create 'images' folder and move files here","confidence":0.90},
        //   {"type":"groupOrphanFiles","description":"Remaining loose files","affectedPaths":["doc.txt"],"suggestedAction":"Create 'orphaned_files' folder and move files here","confidence":0.75}
        // ]

        // CRITICAL: suggestedAction format - you MUST use this exact format:
        // "Create 'foldername' folder and move files here"
        
        // Examples:
        // - For .zip files: "Create 'zip-archives' folder and move files here"
        // - For .pdf files: "Create 'pdfs' folder and move files here"
        // - For Screenshot files: "Create 'screenshots' folder and move files here"
        // - For orphan files: "Create 'orphaned_files' folder and move files here"
        
        // Folder name rules:
        // - Use lowercase, hyphen-separated words
        // - Derive from actual file content (e.g., extension or common prefix)
        // - Wrap in SINGLE quotes like 'this'

        // Rules:
        // - NEVER suggest moving folders themselves - only move FILES into folders
        // - Create destination folders INSIDE the parent folder being analyzed
        // - Never suggest files in: node_modules, .git, .venv, src/, lib/
        // - Ignore hidden files (starting with '.') such as .DS_Store — do not include them in any affectedPaths
        // - Return ONLY the JSON array, no other text
        // - Use full absolute paths in affectedPaths for FILES ONLY (not folders)
        // - confidence must be a number between 0 and 1
        // - Do NOT use vague wording like "Move to Folder/" or "Group files" - you MUST use the exact format above

        // Folders found: \(treeSTR.prefix(3000))
        
        // Output valid JSON array now:
        // """

        let prompt = """
            Analyze the folder structure below and return a JSON array of file organization suggestions.

            STRICT JSON FORMAT:
            [{"type":"groupByNamePattern","description":"Short description","affectedPaths":["/full/path1","/full/path2"],"suggestedAction":"Create 'foldername' folder and move files here","confidence":0.95}]

            STEP-BY-STEP THINKING — follow these steps in order before writing JSON:

            STEP 1 — Scan for name patterns first (highest priority):
            - Do any filenames share a common prefix or naming convention?
            - Example: "Screenshot 2026-02-11...", "Screenshot 2026-02-15..." → these ALL go into 'screenshots', type=groupByNamePattern
            - Example: "Invoice_Jan.pdf", "Invoice_Feb.pdf" → 'invoices', type=groupByNamePattern
            - A name pattern group beats extension grouping — do this first

            STEP 2 — Scan for media type families (second priority):
            - Images: .jpeg .jpg .png .gif .webp .heic → group as 'images' or 'media' UNLESS already caught by Step 1
            - Videos: .mov .mp4 .avi .mkv → group as 'videos' or into 'media' with images if only 1-2 videos
            - Audio: .mp3 .wav .aac → 'audio'
            - IMPORTANT: .jpeg + .mov + .gif = one 'media' folder, NOT three separate extension folders

            STEP 3 — Scan for document families:
            - .pdf .doc .docx .txt → 'documents'
            - Do NOT split .pdf and .docx into separate folders unless there are 4+ of each

            STEP 4 — Scan for archive families:
            - .zip .tar.gz .tar .gz .rar .7z → all go into 'archives' together

            STEP 5 — Scan for developer files:
            - Dockerfile* .env .yaml .yml .sh .toml .json (config) → 'dev-files'
            - Requirements.txt, Makefile, docker-compose.yml → 'dev-files'

            STEP 6 — True orphans only:
            - Only files that did NOT fit any group above → 'orphaned_files'
            - This should be a small group or empty, not a catch-all

            FEW-SHOT EXAMPLE — given these files:
            ajay.jpeg, Movie on 06-02-24 at 8.06 PM.mov, teaser1.gif,
            Screenshot 2026-02-11 at 4.55.10 PM.png, Screenshot 2026-02-15 at 11.42.16 AM.png,
            Screenshot 2026-02-11 at 4.41.35 PM.png, Screenshot 2026-02-17 at 8.42.06 PM.png,
            Lab3_Question_GMM.pdf, DPP 8 Sets and Cardinality.pdf,
            ritesh mera lelo.zip, lemonade_stand (3).tar.gz,
            Dockerfile.frontend

            CORRECT output:
            [
            {"type":"groupByNamePattern","description":"Screenshots grouped by name prefix","affectedPaths":["/path/to/Screenshot 2026-02-11 at 4.55.10 PM.png","/path/to/Screenshot 2026-02-11 at 4.41.35 PM.png","/path/to/Screenshot 2026-02-15 at 11.42.16 AM.png","/path/to/Screenshot 2026-02-17 at 8.42.06 PM.png"],"suggestedAction":"Create 'screenshots' folder and move files here","confidence":0.97},
            {"type":"groupByExtension","description":"PDF documents grouped together","affectedPaths":["/path/to/Lab3_Question_GMM.pdf","/path/to/DPP 8 Sets and Cardinality.pdf"],"suggestedAction":"Create 'documents' folder and move files here","confidence":0.93},
            {"type":"groupByExtension","description":"Compressed archive files","affectedPaths":["/path/to/ritesh mera lelo.zip","/path/to/lemonade_stand (3).tar.gz"],"suggestedAction":"Create 'archives' folder and move files here","confidence":0.91},
            {"type":"groupByExtension","description":"Visual and video media files","affectedPaths":["/path/to/ajay.jpeg","/path/to/Movie on 06-02-24 at 8.06 PM.mov","/path/to/teaser1.gif"],"suggestedAction":"Create 'media' folder and move files here","confidence":0.82},
            {"type":"groupOrphanFiles","description":"Developer config files","affectedPaths":["/path/to/Dockerfile.frontend"],"suggestedAction":"Create 'dev-files' folder and move files here","confidence":0.70}
            ]

            WRONG output (do NOT do this):
            - Putting .jpeg, .mov, .gif into THREE separate folders — wrong, merge into 'media'
            - Putting all files into one 'orphaned_files' — wrong, always split first
            - Missing the Screenshot name pattern and grouping them by .png extension — wrong

            RULES:
            - NEVER move folders, only FILES
            - NEVER include .DS_Store or any file starting with '.' in affectedPaths
            - NEVER create a group with only 1 file unless it is a dev file (Dockerfile, .env, etc.)
            - Return ONLY the JSON array, no explanation text
            - For affectedPaths, use the FULL PATH provided in the input (the "fullPath" field) — do NOT guess or construct paths
            - confidence must be between 0 and 1

            Folders found: \(treeSTR)

            Output valid JSON array now:
            """
                    
        print("LLMEngine: Starting with model: \(selectedModel)")
        logger.debug("Sending prompt to Ollama (length: \(prompt.count))")
        print(String(repeating: "=", count: 20))
        print("tree", treeSTR.prefix(3000))
        print(String(repeating: "=", count: 20))
        
        // Try with format: json first, if fails try without
        var lastError: String = ""
        var rawResponse: String = ""
        
        do {
            let result = try await generateWithOptions(prompt: prompt, useJSONFormat: true)
            if let suggestions = result {
                if !suggestions.isEmpty {
                    return suggestions
                } else {
                    print("LLMEngine: format=true returned empty array, falling through")
                }
            }
        } catch {
            lastError = error.localizedDescription
            print("LLMEngine: format=true threw error: \(lastError)")
        }
        
        do {
            let result = try await generateWithOptions(prompt: prompt, useJSONFormat: false)
            if let suggestions = result {
                if !suggestions.isEmpty {
                    return suggestions
                } else {
                    print("LLMEngine: format=false returned empty array, falling through")
                }
                rawResponse = suggestions.map { "\($0.suggestedAction): \($0.affectedPaths)" }.joined(separator: "\n")
            }
        } catch {
            lastError = error.localizedDescription
            print("LLMEngine: format=false threw error: \(lastError)")
        }
        
        throw NSError(domain: "LLMEngine", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to parse suggestions.\n\nRaw Ollama Response:\n\(rawResponse)\n\nError: \(lastError)"])
    }
    
    private func generateWithOptions(prompt: String, useJSONFormat: Bool) async throws -> [LLMSuggestion]? {
        switch selectedProvider {
        case .ollama:
            return try await generateWithOllama(prompt: prompt, useJSONFormat: useJSONFormat)
        case .groq:
            return try await generateWithGroq(prompt: prompt, useJSONFormat: useJSONFormat)
        }
    }
    
    private func generateWithOllama(prompt: String, useJSONFormat: Bool) async throws -> [LLMSuggestion]? {
        var payload: [String: Any] = [
            "model": selectedModel,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": 0.1,
                "num_predict": 4096
            ]
        ]
        
        if useJSONFormat {
            payload["format"] = "json"
        }
        
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        
        var request = URLRequest(url: ollamaURL)
        request.httpMethod = "POST"
        request.httpBody = payloadData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60.0
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }
        
        guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseText = jsonObject["response"] as? String else {
            let debugStr = String(data: data, encoding: .utf8) ?? "Unable to decode"
            print("LLMEngine: Invalid response format. Raw: \(debugStr)")
            return nil
        }
        
        print("LLMEngine: Raw response (format=\(useJSONFormat)): \(responseText)")
        logger.debug("Ollama response (format=\(useJSONFormat)): \(responseText.prefix(200))")
        
        return parseOllamaResponse(responseText)
    }
    
    private func generateWithGroq(prompt: String, useJSONFormat: Bool) async throws -> [LLMSuggestion]? {
        guard !groqAPIKey.isEmpty else {
            print("LLMEngine: Groq API key is not configured")
            return nil
        }
        
        let payload: [String: Any] = [
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "model": selectedModel,
            "temperature": 1.0,
            "max_completion_tokens": 8192,
            "top_p": 1,
            "stream": false,
            "reasoning_effort": "medium",
            "stop": NSNull()
        ]
        
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        
        var request = URLRequest(url: groqURL)
        request.httpMethod = "POST"
        request.httpBody = payloadData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(groqAPIKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60.0
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let debugStr = String(data: data, encoding: .utf8) ?? "Unable to decode"
            print("LLMEngine: Groq request failed. Raw: \(debugStr)")
            return nil
        }
        
        guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = jsonObject["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let responseText = message["content"] as? String else {
            let debugStr = String(data: data, encoding: .utf8) ?? "Unable to decode"
            print("LLMEngine: Invalid Groq response format. Raw: \(debugStr)")
            return nil
        }
        
        print("LLMEngine: Raw Groq response (format=\(useJSONFormat)): \(responseText)")
        
        return parseOllamaResponse(responseText)
    }
    
    private func parseOllamaResponse(_ responseText: String) -> [LLMSuggestion]? {
        // Step 1: Try parsing as array [LLMSuggestion]
        do {
            let suggestions = try parseJSONResponse(responseText)
            if !suggestions.isEmpty {
                print("LLMEngine: Successfully parsed \(suggestions.count) suggestions")
                return suggestions
            }
        } catch {
            print("LLMEngine: parseJSONResponse failed: \(error)")
        }
        
        // Step 2: If array fails, try single object and wrap in array
        do {
            let cleanResponse = cleanResponseText(responseText)
            if let responseData = cleanResponse.data(using: .utf8) {
                let singleSuggestion = try JSONDecoder().decode(LLMSuggestion.self, from: responseData)
                print("LLMEngine: Successfully parsed single suggestion, wrapping in array")
                return [singleSuggestion]
            }
        } catch {
            print("LLMEngine: Single object parsing failed: \(error)")
        }
        
        // Step 3: Try extractJSONFromText as fallback
        do {
            let suggestions = try extractJSONFromText(responseText)
            if !suggestions.isEmpty {
                print("LLMEngine: Successfully parsed \(suggestions.count) suggestions via extractJSONFromText")
                return suggestions
            }
        } catch {
            print("LLMEngine: extractJSONFromText failed: \(error)")
        }
        
        print("LLMEngine: All parsing methods failed. Raw response: \(responseText)")
        return nil
    }
    
    private func parseJSONResponse(_ text: String) throws -> [LLMSuggestion] {
        let cleanResponse = cleanResponseText(text)
        print("LLMEngine: Cleaned response: \(cleanResponse)")
        
        // Check if response is a single object or array
        var jsonData: Data?
        
        if let responseData = cleanResponse.data(using: .utf8) {
            // First try parsing as-is
            if let suggestions = try? JSONDecoder().decode([LLMSuggestion].self, from: responseData) {
                return suggestions
            }
            
            // Try wrapping single object in array
            if cleanResponse.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
                let wrapped = "[\(cleanResponse)]"
                if let data = wrapped.data(using: .utf8),
                   let suggestions = try? JSONDecoder().decode([LLMSuggestion].self, from: data) {
                    return suggestions
                }
            }
            
            // Try to fix malformed JSON - replace common issues
            var fixed = cleanResponse
            
            // Fix "name": "X" appearing inside arrays (model hallucination)
            // Pattern: ["name": "Music", "name": "Pictures"] -> ["/path/Music", "/path/Pictures"]
            if fixed.range(of: "\"affectedPaths\"\\s*:\\s*\\[", options: .regularExpression) != nil {
                // Try to extract the affectedPaths content and fix it
                if let pathMatch = fixed.range(of: "\"affectedPaths\":\\s*\\[", options: .regularExpression) {
                    let afterPaths = fixed[pathMatch.upperBound...]
                    if let endBracket = afterPaths.firstIndex(of: "]") {
                        let pathsContent = String(afterPaths[..<endBracket])
                        // This is malformed, try to extract just the names
                        var paths: [String] = []
                        let namePattern = "\"name\":\\s*\"([^\"]+)\""
                        if let regex = try? NSRegularExpression(pattern: namePattern) {
                            let nsrange = NSRange(pathsContent.startIndex..., in: pathsContent)
                            let matches = regex.matches(in: pathsContent, range: nsrange)
                            for match in matches {
                                if let nameRange = Range(match.range(at: 1), in: pathsContent) {
                                    paths.append("/" + String(pathsContent[nameRange]))
                                }
                            }
                        }
                        if !paths.isEmpty {
                            let fixedPaths = paths.map { "\"\($0)\"" }.joined(separator: ", ")
                            fixed = fixed.replacingCharacters(in: pathMatch.upperBound..<fixed.index(after: endBracket), with: fixedPaths)
                        }
                    }
                }
            }
            
            jsonData = fixed.data(using: .utf8)
        }
        
        guard let data = jsonData else {
            throw NSError(domain: "LLMEngine", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to convert response to data."])
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode([LLMSuggestion].self, from: data)
    }
    
    private func extractJSONFromText(_ text: String) throws -> [LLMSuggestion] {
        let cleanResponse = cleanResponseText(text)
        
        // Try to find JSON array in the response
        if let startIndex = cleanResponse.firstIndex(of: "["),
           let endIndex = cleanResponse.lastIndex(of: "]") {
            let jsonArray = String(cleanResponse[startIndex...endIndex])
            if let jsonData = jsonArray.data(using: .utf8) {
                let decoder = JSONDecoder()
                return try decoder.decode([LLMSuggestion].self, from: jsonData)
            }
        }
        
        throw NSError(domain: "LLMEngine", code: 5, userInfo: [NSLocalizedDescriptionKey: "No valid JSON array found in response"])
    }
    
    private func cleanResponseText(_ text: String) -> String {
        var cleanResponse = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove markdown code blocks
        if cleanResponse.hasPrefix("```json") {
            cleanResponse = String(cleanResponse.dropFirst(7))
        } else if cleanResponse.hasPrefix("```") {
            cleanResponse = String(cleanResponse.dropFirst(3))
        }
        
        if cleanResponse.hasSuffix("```") {
            cleanResponse = String(cleanResponse.dropLast(3))
        }
        
        return cleanResponse.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
