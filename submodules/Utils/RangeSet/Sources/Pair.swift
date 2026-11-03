//===----------------------------------------------------------*- swift -*-===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

/// A collection of two elements, to avoid heap allocation when calling
/// `replaceSubrange` with just two elements.
@usableFromInline
internal struct Pair<Element>: RandomAccessCollection {
  @usableFromInline
  var pair: (first: Element, second: Element)
  
  @inlinable init(_ first: Element, _ second: Element) {
    self.pair = (first, second)
  }
  
  @inlinable var startIndex: Int { 0 }
  @inlinable var endIndex: Int { 2 }
  
  @inlinable subscript(position: Int) -> Element {
    get {
      switch position {
      case 0: return pair.first
      case 1: return pair.second
      default: fatalError("Index '\(position)' is out of range")
      }
    }
  }
}
