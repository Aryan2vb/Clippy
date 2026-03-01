import Foundation
import ClippyCore
import os.log

public class LLMEngine: @unchecked Sendable {
    private let ollamaURL = URL(string: "http://localhost:11434/api/generate")!
    // public var selectedModel: String = "llama3.2"
    public var selectedModel: String = "llama3.2:3b"    
    
    private let logger = Logger(subsystem: "Clippy", category: "LLMEngine")
    
    public init() {}
    
    // Check if Ollama is running
    public func isOllamaAvailable() async -> Bool {
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/tags")!)
        // Ensure we don't hang if Ollama is off
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
    
    // Generate suggestions from folder tree
    public func generateSuggestions(folderTree: FolderTreeSummary) async throws -> [LLMSuggestion] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let treeJSONData = try encoder.encode(folderTree)
        let treeSTR = String(data: treeJSONData, encoding: .utf8) ?? ""
        
        let prompt = """
        Analyze the folder structure below and return a JSON array of suggestions.

        STRICT JSON FORMAT - you MUST follow this exactly:
        [{"type":"groupOrphanFiles","description":"Short description","affectedPaths":["/full/path1","/full/path2"],"suggestedAction":"Move to Folder/","confidence":0.85}]

        Rules:
        - Never suggest files in: node_modules, .git, .venv, src/, lib/
        - Return ONLY the JSON array, no other text
        - Use full absolute paths in affectedPaths
        - confidence must be a number between 0 and 1

        Folders found: \(treeSTR.prefix(2000))
        
        Output valid JSON array now:
        """
        
        print("LLMEngine: Starting with model: \(selectedModel)")
        logger.debug("Sending prompt to Ollama (length: \(prompt.count))")
        
        // Try with format: json first, if fails try without
        var lastError: String = ""
        var rawResponse: String = ""
        
        do {
            let result = try await generateWithOptions(prompt: prompt, useJSONFormat: true)
            if let suggestions = result, !suggestions.isEmpty {
                return suggestions
            }
        } catch {
            lastError = error.localizedDescription
        }
        
        do {
            let result = try await generateWithOptions(prompt: prompt, useJSONFormat: false)
            if let suggestions = result, !suggestions.isEmpty {
                return suggestions
            }
            rawResponse = result ?? ""
        } catch {
            lastError = error.localizedDescription
        }
        
        throw NSError(domain: "LLMEngine", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to parse suggestions.\n\nRaw Ollama Response:\n\(rawResponse)\n\nError: \(lastError)"])
    }
    
    private func generateWithOptions(prompt: String, useJSONFormat: Bool) async throws -> [LLMSuggestion]? {
        var payload: [String: Any] = [
            "model": selectedModel,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": 0.1,
                "num_predict": 512
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
            // Log full response for debugging
            let debugStr = String(data: data, encoding: .utf8) ?? "Unable to decode"
            print("LLMEngine: Invalid response format. Raw: \(debugStr)")
            return nil
        }
        
        print("LLMEngine: Raw response (format=\(useJSONFormat)): \(responseText)")
        logger.debug("Ollama response (format=\(useJSONFormat)): \(responseText.prefix(200))")
        
        return parseOllamaResponse(responseText)
    }
    
    private func parseOllamaResponse(_ responseText: String) -> [LLMSuggestion]? {
        // Try to parse the response as JSON
        var suggestions = try? parseJSONResponse(responseText)
        
        // If JSON parsing fails, try to extract JSON from text
        if suggestions == nil || suggestions!.isEmpty {
            suggestions = try? extractJSONFromText(responseText)
        }
        
        return suggestions
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
            if fixed.contains("\"affectedPaths\": [") {
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
        var cleanResponse = cleanResponseText(text)
        
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
