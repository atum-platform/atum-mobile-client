import Foundation
import CoreText
let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath:path)
guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], let descriptor = descriptors.first else { fatalError("Native font failed to decode") }
let font = CTFontCreateWithFontDescriptor(descriptor, 24, nil)
let sample = try String(contentsOfFile:CommandLine.arguments[2], encoding:.utf8)
let missing = sample.unicodeScalars.filter { scalar in
    var character = UniChar(scalar.value)
    var glyph = CGGlyph()
    return !CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) || glyph == 0
}.map { String($0) }
let result: [String:Any] = ["postScriptName":CTFontCopyPostScriptName(font) as String, "testedAlphabeticScalars":sample.unicodeScalars.count, "missingGlyphs":missing, "status":missing.isEmpty ? "PASS" : "FAIL", "scope":"macOS CoreText native-font decoding and approved Vietnamese copy glyph coverage; device typography remains P2"]
let data = try JSONSerialization.data(withJSONObject:result, options:[.prettyPrinted,.sortedKeys])
FileHandle.standardOutput.write(data)
if !missing.isEmpty { exit(1) }
