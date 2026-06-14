import Foundation

class ASRTextProcessor {
    
    enum MarkerType: String {
        case arabic
        case chinese
        case ordinal
        case logical
    }
    
    struct Marker {
        let range: NSRange
        let text: String
        let value: Int
        let type: MarkerType
        let fullMatchRange: NSRange
    }
    
    /// 过滤语气词
    static func filterFillerWords(_ text: String) -> String {
        var result = text
        
        // 1. 无脑去除 "呃" 和连续的 "呃"
        result = result.replacingOccurrences(of: "呃+", with: "", options: .regularExpression)
        
        // 2. 匹配句首或标点符号前后的语气停顿词：
        // 开头的 "那个[，, ]?"，"这个[，, ]?"，"就是说[，, ]?"，"嗯[，, ]?"，"啊[，, ]?"
        let prefixPattern = "^(那个|这个|就是说|嗯|啊|呀)[，,、\\s]*"
        result = result.replacingOccurrences(of: prefixPattern, with: "", options: .regularExpression)
        
        // 标点符号后的语气停顿词
        let middlePattern = "([，,、。？！；：\\s])(那个|这个|就是说|嗯|啊|呀)([，,、\\s]*)"
        result = result.replacingOccurrences(of: middlePattern, with: "$1", options: .regularExpression)
        
        // 3. 清理多余标点
        result = cleanPunctuation(result)
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private static func cleanPunctuation(_ text: String) -> String {
        var cleaned = text
        cleaned = cleaned.replacingOccurrences(of: "，+、*", with: "，", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: ",+", with: ",", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "，\\s*，", with: "，", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "，\\s*[。？！]", with: "$1", options: .regularExpression)
        // 移除开头的所有标点符号、省略号 and 空白
        cleaned = cleaned.replacingOccurrences(of: "^[，,。、？\\?！\\!；;：:…\\s]+", with: "", options: .regularExpression)
        return cleaned
    }
    
    /// 结构化排版
    static func formatStructuredInput(_ text: String) -> String {
        let nsText = text as NSString
        var markers: [Marker] = []
        
        // 1. 阿拉伯数字匹配
        let arabicRegex = try? NSRegularExpression(pattern: "(?:^|[^\\d])(\\d+)(?:\\.|、|\\s+|：)(?=\\S)", options: [])
        if let matches = arabicRegex?.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) {
            for match in matches {
                if match.numberOfRanges >= 2 {
                    let numRange = match.range(at: 1)
                    let numStr = nsText.substring(with: numRange)
                    if let val = Int(numStr) {
                        markers.append(Marker(range: numRange, text: numStr, value: val, type: .arabic, fullMatchRange: match.range))
                    }
                }
            }
        }
        
        // 2. 中文数字匹配 (去掉前缀限制)
        let chineseRegex = try? NSRegularExpression(pattern: "([一二三四五六七八九十]+)(?:、|，)(?=\\S)", options: [])
        let chineseNums = ["一":1,"二":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9,"十":10]
        if let matches = chineseRegex?.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) {
            for match in matches {
                if match.numberOfRanges >= 2 {
                    let numRange = match.range(at: 1)
                    let numStr = nsText.substring(with: numRange)
                    if let val = chineseNums[numStr] {
                        markers.append(Marker(range: numRange, text: numStr, value: val, type: .chinese, fullMatchRange: match.range))
                    }
                }
            }
        }
        
        // 3. "第X"匹配 (去掉前缀限制)
        let ordinalRegex = try? NSRegularExpression(pattern: "(第一|第二|第三|第四|第五|第六|第七|第八|第九|第十)(?:点|步|个|条)?(?:是|，|、|：)?(?=\\S)", options: [])
        let ordinalNums = ["第一":1,"第二":2,"第三":3,"第四":4,"第五":5,"第六":6,"第七":7,"第八":8,"第九":9,"第十":10]
        if let matches = ordinalRegex?.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) {
            for match in matches {
                if match.numberOfRanges >= 2 {
                    let numRange = match.range(at: 1)
                    let numStr = nsText.substring(with: numRange)
                    if let val = ordinalNums[numStr] {
                        markers.append(Marker(range: numRange, text: numStr, value: val, type: .ordinal, fullMatchRange: match.range))
                    }
                }
            }
        }
        
        // 4. 逻辑关系词匹配 (去掉前缀限制)
        let logicalRegex = try? NSRegularExpression(pattern: "(首先|其次|再次|最后|此外|另外)(?:，|、|：)?(?=\\S)", options: [])
        let logicalVals = ["首先":1, "其次":2, "再次":3, "此外":4, "另外":4, "最后":99]
        if let matches = logicalRegex?.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) {
            for match in matches {
                if match.numberOfRanges >= 2 {
                    let wordRange = match.range(at: 1)
                    let wordStr = nsText.substring(with: wordRange)
                    if let val = logicalVals[wordStr] {
                        markers.append(Marker(range: wordRange, text: wordStr, value: val, type: .logical, fullMatchRange: match.range))
                    }
                }
            }
        }
        
        markers.sort { $0.range.location < $1.range.location }
        
        var validRangesToInsertNewlineBefore = [Int]()
        
        let types: [MarkerType] = [.arabic, .chinese, .ordinal, .logical]
        for type in types {
            let filtered = markers.filter { $0.type == type }
            if filtered.count < 2 { continue }
            
            var lastVal = -1
            var lastLoc = -1
            var sequence = [Marker]()
            
            for m in filtered {
                let isIncrement = m.value > lastVal || (m.value == 99 && lastVal != 99 && lastVal != -1)
                let isFarEnough = lastLoc == -1 || (m.range.location - lastLoc) >= 2
                
                if isIncrement && isFarEnough {
                    sequence.append(m)
                    lastVal = m.value
                    lastLoc = m.range.location + m.range.length
                }
            }
            
            if sequence.count >= 2 {
                for (idx, m) in sequence.enumerated() {
                    let loc = m.range.location
                    if idx == 0 && loc == 0 {
                        continue
                    }
                    if !validRangesToInsertNewlineBefore.contains(loc) {
                        validRangesToInsertNewlineBefore.append(loc)
                    }
                }
            }
        }
        
        if validRangesToInsertNewlineBefore.isEmpty {
            return text
        }
        
        validRangesToInsertNewlineBefore.sort(by: >)
        var resultText = text
        for loc in validRangesToInsertNewlineBefore {
            let index = resultText.index(resultText.startIndex, offsetBy: loc)
            resultText.insert("\n", at: index)
        }
        
        return resultText
    }
}
