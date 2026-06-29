import Foundation
import ZIPFoundation

// Writes a clean, elegant .docx (a .docx is a ZIP of OOXML parts; no Microsoft or
// Word dependency). The exact OOXML parts, content types, relationship URIs, and
// schema-significant element ordering were verified against the WordprocessingML
// spec and round-trip-validated (unzip, xmllint, textutil) on 2026-06-29. Typography
// is set in styles.xml: a Title, Heading 1/2, a readable Normal body, and a real
// bullet list via numbering.xml. Apple-spirited document design: clear hierarchy,
// generous spacing, restrained typography, very readable.
public enum DocxBlock: Sendable {
    case heading1(String)
    case heading2(String)
    case paragraph(String)
    case bullet(String)
}

public enum DocxWriter {
    // Change these two to restyle the whole document.
    private static let headingFont = "Helvetica Neue"   // Title + Heading 1/2
    private static let bodyFont = "Georgia"             // Normal + List Paragraph

    enum DocxError: Error { case archiveDataUnavailable }

    public static func write(title: String, blocks: [DocxBlock], to url: URL) throws {
        var body = paragraph(styleId: "Title", text: title)
        for block in blocks {
            switch block {
            case .heading1(let t): body += paragraph(styleId: "Heading1", text: t)
            case .heading2(let t): body += paragraph(styleId: "Heading2", text: t)
            case .paragraph(let t): body += paragraph(styleId: "Normal", text: t)
            case .bullet(let t): body += bulletParagraph(text: t)
            }
        }
        body += sectionProperties

        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>
        \(body)
        </w:body>
        </w:document>
        """

        let archive = try Archive(accessMode: .create)
        try archive.addFile("[Content_Types].xml", xml: contentTypesXML)
        try archive.addFile("_rels/.rels", xml: rootRelsXML)
        try archive.addFile("word/document.xml", xml: documentXML)
        try archive.addFile("word/_rels/document.xml.rels", xml: documentRelsXML)
        try archive.addFile("word/styles.xml", xml: stylesXML)
        try archive.addFile("word/numbering.xml", xml: numberingXML)

        guard let data = archive.data else { throw DocxError.archiveDataUnavailable }
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Body builders

    private static func esc(_ s: String) -> String {
        var out = ""; out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }

    private static func paragraph(styleId: String, text: String) -> String {
        "<w:p><w:pPr><w:pStyle w:val=\"\(styleId)\"/></w:pPr><w:r><w:t xml:space=\"preserve\">\(esc(text))</w:t></w:r></w:p>"
    }
    private static func bulletParagraph(text: String) -> String {
        "<w:p><w:pPr><w:pStyle w:val=\"ListParagraph\"/><w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t xml:space=\"preserve\">\(esc(text))</w:t></w:r></w:p>"
    }

    // A4, 1-inch margins. Must be the LAST child of <w:body>.
    private static let sectionProperties = """
    <w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>
    """

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
    <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
    </Types>
    """

    private static let rootRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    private static let documentRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
    </Relationships>
    """

    private static let numberingXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:abstractNum w:abstractNumId="0">
    <w:multiLevelType w:val="hybridMultilevel"/>
    <w:lvl w:ilvl="0">
    <w:start w:val="1"/>
    <w:numFmt w:val="bullet"/>
    <w:lvlText w:val="&#8226;"/>
    <w:lvlJc w:val="left"/>
    <w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr>
    </w:lvl>
    </w:abstractNum>
    <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
    </w:numbering>
    """

    private static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:docDefaults>
    <w:rPrDefault><w:rPr><w:rFonts w:ascii="\(bodyFont)" w:hAnsi="\(bodyFont)" w:cs="\(bodyFont)"/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:rPrDefault>
    <w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault>
    </w:docDefaults>
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
    <w:style w:type="paragraph" w:styleId="Title">
    <w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>
    <w:pPr><w:spacing w:before="0" w:after="240" w:line="240" w:lineRule="auto"/></w:pPr>
    <w:rPr><w:rFonts w:ascii="\(headingFont)" w:hAnsi="\(headingFont)" w:cs="\(headingFont)"/><w:b/><w:color w:val="1F2933"/><w:sz w:val="56"/><w:szCs w:val="56"/></w:rPr>
    </w:style>
    <w:style w:type="paragraph" w:styleId="Heading1">
    <w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>
    <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="320" w:after="120" w:line="240" w:lineRule="auto"/><w:outlineLvl w:val="0"/></w:pPr>
    <w:rPr><w:rFonts w:ascii="\(headingFont)" w:hAnsi="\(headingFont)" w:cs="\(headingFont)"/><w:b/><w:color w:val="2A4D69"/><w:sz w:val="32"/><w:szCs w:val="32"/></w:rPr>
    </w:style>
    <w:style w:type="paragraph" w:styleId="Heading2">
    <w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>
    <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="240" w:after="80" w:line="240" w:lineRule="auto"/><w:outlineLvl w:val="1"/></w:pPr>
    <w:rPr><w:rFonts w:ascii="\(headingFont)" w:hAnsi="\(headingFont)" w:cs="\(headingFont)"/><w:b/><w:color w:val="2A4D69"/><w:sz w:val="26"/><w:szCs w:val="26"/></w:rPr>
    </w:style>
    <w:style w:type="paragraph" w:styleId="ListParagraph">
    <w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:uiPriority w:val="34"/><w:qFormat/>
    <w:pPr><w:ind w:left="720"/><w:contextualSpacing/></w:pPr>
    </w:style>
    </w:styles>
    """
}

private extension Archive {
    func addFile(_ path: String, xml: String) throws {
        let data = Data(xml.utf8)
        try addEntry(with: path, type: .file,
                     uncompressedSize: Int64(data.count),
                     compressionMethod: .deflate,
                     provider: { position, size in
            // ZIPFoundation clamps `size` on the final chunk, so this never overruns.
            data.subdata(in: Data.Index(position) ..< Int(position) + size)
        })
    }
}
