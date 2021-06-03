//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

#if compiler(>=5.5) // we cannot write this on one line with `&&` because Swift 5.0 doesn't like it...
#if compiler(>=5.5) && $AsyncAwait
import _Concurrency

@available(macOS 9999, iOS 9999, watchOS 9999, tvOS 9999, *)
public final class InboundAsyncSequence<InboundIn>: ChannelInboundHandler, AsyncSequence {
  
  public typealias Element = InboundIn
  
  public struct AsyncIterator: AsyncIteratorProtocol {
    public mutating func next() async throws -> Element? {
      guard case .iterating(let handler, var iterator) = state else {
        return nil
      }
      
      let nextEvent: Event
      if let next = iterator?.next() {
        nextEvent = next
      } else {
        var mutableEvent: Event?
        while true {
          iterator = try await handler.nextEvents.makeIterator()
          if let next = iterator?.next() {
            mutableEvent = next
            break
          } else {
            /// `channelReadComplete` was called with no corresponding calls to `channelRead`
            continue
          }
        }
        nextEvent = mutableEvent!
      }
      
      switch nextEvent {
      case .channelInactive, .inputClosed:
        state = .complete
        return nil
      case .read(let element):
        state = .iterating(handler, iterator)
        return element
      }
    }
    
    fileprivate init(handler: InboundAsyncSequence) {
      state = .iterating(handler, nil)
    }
    private enum State {
      case iterating(InboundAsyncSequence, Array<Event>.Iterator?)
      case complete
    }
    private var state: State
  }
  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(handler: self)
  }
  
  public func handlerAdded(context: ChannelHandlerContext) {
    precondition(continuation == nil)
    /// We expect `autoRead` to be `false`, so we need a context on which to first call `read`
    self.context = context
  }
  
  public func handlerRemoved(context: ChannelHandlerContext) {
    /// No one should be awaitng on this handler when it is removed
    precondition(continuation == nil)
    self.context = nil
  }
  
  public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    print((unwrapInboundIn(data) as? ByteBuffer).map(String.init)!)
    enqueue(.read(unwrapInboundIn(data)))
    context.fireChannelRead(data)
  }
  
  public func channelReadComplete(context: ChannelHandlerContext) {
    context.fireChannelReadComplete()
    flushEvents()
  }
  
  public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    defer { context.fireUserInboundEventTriggered(event) }
    if case .inputClosed = event as? ChannelEvent {
      print(#function)
      enqueue(.inputClosed)
      flushEvents()
      
      switch state {
      case .idle:
        state = .inputClosed(remainder: [.inputClosed])
      case .buffered(let events):
        state = .inputClosed(remainder: events)
      case .inputClosed:
        preconditionFailure()
      }
    }
  }
  
  public func channelInactive(context: ChannelHandlerContext) {
    if case .inputClosed = state { return }
    enqueue(.channelInactive)
    context.fireChannelInactive()
    flushEvents()
  }
  
  private enum Event {
    case read(InboundIn)
    case channelInactive
    case inputClosed
  }
  
  private func enqueue(_ event: Event) {
    switch state {
    case .idle:
      state = .buffered([event])
    case .buffered(var events):
      events.append(event)
      state = .buffered(events)
    case .inputClosed:
      preconditionFailure()
    }
  }
  
  private func flushEvents() {
    guard let continuation = continuation else {
      return
    }
    self.continuation = nil
    
    let result: [Event]
    switch state {
    case .idle:
      result = []
    case .buffered(let events):
      state = .idle
      result = events
    case .inputClosed(let remainder):
      state = .inputClosed(remainder: [.inputClosed])
      result = remainder
    }
    continuation.resume(returning: result)
  }
  
  private var nextEvents: [Event] {
    get async throws {
      try await withCheckedThrowingContinuation { continuation in
        context.eventLoop.execute { [self] in
          
          /// We expect to only await on handlers that are part of a `ChannelPipeline`
          precondition(context != nil)
          
          switch self.continuation {
          case let oldValue?:
            assertionFailure()
            oldValue.resume(throwing: Error.multipleConcurrentListeners)
            continuation.resume(throwing: Error.multipleConcurrentListeners)
          case nil:
            break
          }
          
          switch state {
          case .idle:
            self.continuation = continuation
            context.read()
          case .buffered(let events):
            continuation.resume(returning: events)
          case .inputClosed(let remainder):
            continuation.resume(returning: remainder)
          }
        }
      }
    }
  }
  
  private enum Error: Swift.Error {
    case multipleConcurrentListeners
  }
  
  private enum State {
    case idle
    case buffered([Event])
    case inputClosed(remainder: [Event])
  }
  private var state: State = .idle
  private var context: ChannelHandlerContext!
  private var continuation: CheckedContinuation<[Event], Swift.Error>?
}

#endif
#endif
