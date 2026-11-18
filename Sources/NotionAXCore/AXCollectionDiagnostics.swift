import Foundation
import ApplicationServices

public struct AXCollectionDiagnostics: Codable, Sendable {
    public var fields: [String:String]
    public var queryResults: [String:Int]
    public init(fields:[String:String] = [:],queryResults:[String:Int] = [:]) { self.fields=fields;self.queryResults=queryResults }
}
/// Scoped to the existing serial AX traversal. Counts results without adding AX calls.
package final class AXQueryDiagnostics {
    var counts: [String:Int] = [:]
    func record(_ name:String,_ result:AXError) {
        let key="\(name):\(result.rawValue)"
        if counts[key] != nil || counts.count<200 { counts[key,default:0]+=1 }
        else { counts["other",default:0]+=1 }
    }
}
package func recordAXResult(_ name:String,_ result:AXError) {
    (Thread.current.threadDictionary["rearview.ax.diagnostics"] as? AXQueryDiagnostics)?.record(name,result)
}
