import SwiftUI

// Resolve the established property-wrapper spelling locally. SDK 27 also exports
// a State macro, whose plugin is absent from Command Line Tools installations.
// This preserves the existing views and their SwiftUI state storage semantics.
typealias SyrtisState<Value> = SwiftUI.State<Value>
