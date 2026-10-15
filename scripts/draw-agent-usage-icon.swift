// Original vector artwork for the Agent Usage fleet build; no upstream logo reuse.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
let iconset=root.appendingPathComponent("agent-usage.iconset",isDirectory:true)
try FileManager.default.createDirectory(at:iconset,withIntermediateDirectories:true)
func glyph(_ c:CGContext,_ scale:CGFloat,_ color:CGColor) {
    c.saveGState();c.scaleBy(x:scale,y:scale);c.setFillColor(color)
    for (x,h) in [(CGFloat(21),CGFloat(30)),(CGFloat(43),CGFloat(53)),(CGFloat(65),CGFloat(41))] {
        c.addPath(CGPath(roundedRect:CGRect(x:x,y:26,width:14,height:h),cornerWidth:4,cornerHeight:4,transform:nil));c.fillPath()
    }
    c.addPath(CGPath(roundedRect:CGRect(x:18,y:17,width:64,height:5),cornerWidth:2.5,cornerHeight:2.5,transform:nil));c.fillPath();c.restoreGState()
}
let purple=CGColor(red:0.32,green:0.28,blue:0.86,alpha:1)
for (name,size) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    let c=CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:size*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    let n=CGFloat(size)
    c.setFillColor(purple);c.addPath(CGPath(roundedRect:CGRect(x:n*0.07,y:n*0.07,width:n*0.86,height:n*0.86),cornerWidth:n*0.18,cornerHeight:n*0.18,transform:nil));c.fillPath()
    glyph(c,n/100,CGColor(gray:1,alpha:1))
    let dest=CGImageDestinationCreateWithURL(iconset.appendingPathComponent("icon_\(name).png") as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(dest,c.makeImage()!,nil);guard CGImageDestinationFinalize(dest) else {fatalError("icon_write_failed")}
}
var box=CGRect(x:0,y:0,width:100,height:100)
let pdf=CGContext(root.appendingPathComponent("agent-usage-mark.pdf") as CFURL,mediaBox:&box,nil)!
pdf.beginPDFPage(nil);glyph(pdf,1,purple);pdf.endPDFPage();pdf.closePDF()
