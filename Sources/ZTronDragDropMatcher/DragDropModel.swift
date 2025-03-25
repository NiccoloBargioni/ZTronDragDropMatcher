import SwiftUI

public final class DragDropModel<Draggable: Hashable & Sendable, Droppable: DragDropEntity, DroppableIndex: Hashable>: ObservableObject, @unchecked Sendable {
    private var tree: DynamicTree<any DragDropEntity> = .init()
    private let treeLock = DispatchSemaphore(value: 1)

    private var tileToSizeMap: [Draggable: CGSize] = [:]
    private let tileToSizeMapLock: DispatchSemaphore = .init(value: 1)
    
    @Published private var draggingEntity: Draggable? = nil
    private let draggingEntityLock: DispatchSemaphore = .init(value: 1)
    
    // MARK: - HANDLE PROXIES FOR DROP DESTINATION IN AABB TREE
    private var dropDestinationIndices: [Droppable: Int] = [:]
    private let dropDestinationLock: DispatchSemaphore = .init(value: 1)
    
    // MARK: - DRAG AND DROP REQUIRES PERSISTING UUIDs
    private let tilesID: [Draggable: UUID]
    
    // MARK: - HANDLE DISPLAYING ALREADY POSITIONED SYMBOLS
    @Published private var firstMatchingSymbolsSet: [Draggable]
    @Published private var secondMatchingSymbolsSet: [Draggable]
    
    private let firstMatchingSymbolsSetLock: DispatchSemaphore = .init(value: 1)
    private let secondMatchingSymbolsSetLock: DispatchSemaphore = .init(value: 1)
    
    // MARK: - HANDLE REORDERING DROP DESTINATIONS
    @Published private var dropDestinationsOrder: [DroppableIndex]
    private let dropDestinationsOrderLock: DispatchSemaphore = .init(value: 1)

    private var delegate: (any DragDropDelegate<Draggable, Droppable, DroppableIndex>)? = nil
    private let delegateLock: DispatchSemaphore = .init(value: 1)
    
    private var lastCollidedDroppable: Droppable? = nil
    private let lastCollidedDroppableLock: DispatchSemaphore = .init(value: 1)
    
    // MARK: - HANDLE ASSIGNED DROPPABLES
    @Published private var firstSymbolsSlots: [Droppable: Draggable] = [:]
    @Published private var secondSymbolsSlots: [Droppable: Draggable] = [:]
    
    private let firstSymbolsSlotsLock: DispatchSemaphore = .init(value: 1)
    private let secondSymbolsSlotsLock: DispatchSemaphore = .init(value: 1)

    private var registeredDroppables: [Droppable] = []
    private var registeredDroppablesLock: DispatchSemaphore = .init(value: 1)
    
    public init(
        firstSet: [Draggable],
        secondSet: [Draggable],
        droppableIndices: [DroppableIndex]
    ) {
        self.firstMatchingSymbolsSet = firstSet
        self.secondMatchingSymbolsSet = secondSet
        
        self.tilesID = firstSet.appending(contentsOf: secondSet).reduce(into: [:]) { result, tile in
            result[tile] = UUID()
        }
        
        self.dropDestinationsOrder = droppableIndices
    }
    
    
    @discardableResult public final func registerDropDestination(_ destination: Droppable, at: CGRect, move: Bool = true) -> Bool {
        self.dropDestinationLock.wait()
        if let destinationIndex = dropDestinationIndices[destination] {
            if move {
                self.dropDestinationLock.signal()
                return tree.moveProxy(index: destinationIndex, aabb: at)
            }
        } else {
            dropDestinationIndices[destination] = tree.createProxy(aabb: at, item: destination)
            self.registeredDroppablesLock.wait()
            self.registeredDroppables.append(destination)
            self.registeredDroppablesLock.signal()
        }
        
        self.dropDestinationLock.signal()
        return true
    }
    
    public final func registerDraggableSize(_ entity: Draggable, size: CGSize, onConflict: DragDropModel.OnRegisterConflict = .replace) {
        self.tileToSizeMapLock.wait()

        defer {
            self.tileToSizeMapLock.signal()
        }
        
        if self.tileToSizeMap[entity] != nil {
            if onConflict == .replace {
                self.tileToSizeMap[entity] = size
            }
        } else {
            self.tileToSizeMap[entity] = size
        }
    }
    
    public final func setActiveDraggable(_ entity: Draggable) {
        self.draggingEntityLock.wait()
        self.draggingEntity = entity
        self.draggingEntityLock.signal()
    }

    
    internal final func overlaps(_ draggingEntityOrigin: CGPoint) -> (Droppable, CGFloat)? {
        self.tileToSizeMapLock.wait()
        self.draggingEntityLock.wait()
        defer {
            self.draggingEntityLock.signal()
            self.tileToSizeMapLock.signal()
        }
        
        
        guard let draggingEntity = self.draggingEntity else { return nil }
        guard let draggingEntitySize = self.tileToSizeMap[draggingEntity] else { return nil }


        var allOverlaps: [(Droppable, CGFloat)] = .init()
        
        let targetLocation = CGRect(
            origin: draggingEntityOrigin,
            size: draggingEntitySize
        )
        
        self.treeLock.wait()
        
        self.tree.query(aabb: targetLocation) { dropEntity, dropEntityBoundingBox in
            guard let dropEntity = dropEntity as? Droppable else { return false }
                        
            let intersection = CGRectIntersection(
                targetLocation,
                dropEntityBoundingBox
            )
                        
            allOverlaps.append((dropEntity, intersection.height/Swift.max(draggingEntitySize.height, dropEntityBoundingBox.height)))
            
            return false
        }
        
        self.treeLock.signal()
        
        if let maxOverlap = allOverlaps.max(by: { lhs, rhs in
            return lhs.1 < rhs.1
        }) {
            return maxOverlap
        }

        return nil
    }
    
    
    public final func onDragUpdated(_ draggingEntityOrigin: CGPoint) {
        self.draggingEntityLock.wait()
        guard let draggingEntity = self.draggingEntity else {
            self.draggingEntityLock.signal()
            return
        }
        self.draggingEntityLock.signal()
        
        let overlap = self.overlaps(draggingEntityOrigin)
        
        guard let delegate = self.delegate else { return }

        self.draggingEntityLock.wait()
        self.lastCollidedDroppableLock.wait()
        if let overlap = overlap {
            self.lastCollidedDroppable = overlap.0
            delegate.onDragUpdated(.init(draggable: draggingEntity, droppable: overlap.0))
        } else {
            self.lastCollidedDroppable = nil
        }
        self.lastCollidedDroppableLock.signal()
        self.draggingEntityLock.signal()
    }

    public final func onDroppableMoved(movedIndices: IndexSet, destination: Int) {
        self.dropDestinationsOrderLock.wait()
        
        for startingIndex in movedIndices {
            guard startingIndex != destination else { continue }
            let elementToMove = self.dropDestinationsOrder[startingIndex]
            
            var newOrder: [DroppableIndex] = .init()
            
            for index in self.dropDestinationsOrder {
                newOrder.append(index)
            }
            
            if startingIndex < destination {
                for index in startingIndex+1..<destination {
                    newOrder[index - 1] = newOrder[index]
                }
                
                newOrder[destination - 1] = elementToMove
            } else {
                for i in (destination+1...startingIndex).reversed() {
                    newOrder[i] = newOrder[i-1]
                }
                
                newOrder[destination] = elementToMove
            }
            
            self.dropDestinationsOrder = newOrder
        }
        
        self.dropDestinationsOrderLock.signal()
    }
    
    public final func validateDrop() -> Bool {
        self.draggingEntityLock.wait()
        self.lastCollidedDroppableLock.wait()
        
        defer {
            self.lastCollidedDroppableLock.signal()
            self.draggingEntityLock.signal()
        }
        
        guard let draggingEntity = self.draggingEntity else { return false }
        guard let lastDroppable = self.lastCollidedDroppable else { return false }
        guard let delegate = self.delegate else { return true }
        
        return delegate.validateDrop(
            .init(
                draggable: draggingEntity,
                droppable: lastDroppable
            )
        )
    }

    public final func getFirstDraggableSet() -> [Draggable] {
        var copy = [Draggable].init()
        
        self.firstMatchingSymbolsSetLock.wait()
        for symbol in self.firstMatchingSymbolsSet {
            copy.append(symbol)
        }
        self.firstMatchingSymbolsSetLock.signal()
        
        self.delegateLock.wait()
        
        defer {
            self.delegateLock.signal()
        }
        
        guard let delegate = self.delegate else {
            self.delegateLock.signal()
            return copy
        }
        
        return copy.sorted { lhs, rhs in
            return delegate.priority(for: lhs) < delegate.priority(for: rhs)
        }
    }
    
    public final func getSecondDraggableSet() -> [Draggable] {
        var copy = [Draggable].init()
        
        self.secondMatchingSymbolsSetLock.wait()
        for symbol in self.secondMatchingSymbolsSet {
            copy.append(symbol)
        }
        self.secondMatchingSymbolsSetLock.signal()
        
        self.delegateLock.wait()
        
        defer {
            delegateLock.signal()
        }
        
        guard let delegate = self.delegate else {
            return copy
        }
        
        return copy.sorted { lhs, rhs in
            return delegate.priority(for: lhs) < delegate.priority(for: rhs)
        }
    }
 
    public final func revertSelection(for droppable: Droppable) {
        self.delegateLock.wait()
        guard let delegate = self.delegate else {
            self.delegateLock.signal()
            return
        }
        
        self.firstSymbolsSlotsLock.wait()
        self.secondSymbolsSlotsLock.wait()

        let matchedSymbol = self.firstSymbolsSlots[droppable] ?? self.secondSymbolsSlots[droppable]
        let side = self.firstSymbolsSlots[droppable] == matchedSymbol ? SymbolsSet.first : SymbolsSet.second
        
        self.secondSymbolsSlotsLock.signal()
        self.firstSymbolsSlotsLock.signal()
        
        if let matchedSymbol = matchedSymbol {
            if side == .first {
                self.firstMatchingSymbolsSetLock.wait()
                self.firstMatchingSymbolsSet.append(matchedSymbol)
                self.firstMatchingSymbolsSetLock.signal()
                
                self.firstSymbolsSlotsLock.wait()
                self.firstSymbolsSlots[droppable] = nil
                self.firstSymbolsSlotsLock.signal()
            } else {
                self.secondMatchingSymbolsSetLock.wait()
                self.secondMatchingSymbolsSet.append(matchedSymbol)
                self.secondMatchingSymbolsSetLock.signal()
                
                self.secondSymbolsSlotsLock.wait()
                self.secondSymbolsSlots[droppable] = nil
                self.secondSymbolsSlotsLock.signal()
            }
            
            delegate.revertSelection(matchedSymbol)
        }
        
        self.delegateLock.signal()
    }
    
    private final func canAutocompletetSet(_ set: SymbolsSet) -> Bool {
        (set == .first ? self.firstMatchingSymbolsSetLock : self.secondMatchingSymbolsSetLock).wait()
        defer {
            (set == .first ? self.firstMatchingSymbolsSetLock : self.secondMatchingSymbolsSetLock).signal()
        }
        
        return set == .first ?  self.firstMatchingSymbolsSet.count == 1 : self.secondMatchingSymbolsSet.count == 1
    }
    
    internal func autocompleteSetIfPossible(_ set: SymbolsSet) {
        guard self.canAutocompletetSet(set) else { return }
        
        (set == .first ? self.firstMatchingSymbolsSetLock : self.secondMatchingSymbolsSetLock).wait()
        
        guard let onlyLeftSymbol = set == .first ? self.firstMatchingSymbolsSet.first : secondMatchingSymbolsSet.first else {
            (set == .first ? self.firstMatchingSymbolsSetLock : self.secondMatchingSymbolsSetLock).signal()
            return
        }
        
        self.delegateLock.wait()
        self.registeredDroppablesLock.wait()
        defer {
            self.registeredDroppablesLock.signal()
            self.delegateLock.signal()
        }
        guard let delegate = self.delegate else { return }
        
        (set == .first ? self.firstSymbolsSlotsLock : self.secondSymbolsSlotsLock).wait()
        guard let onlyLeftDroppable = self.registeredDroppables.first(where: { droppable in
            return delegate.classify(droppable: droppable) == set && (set == .first ? self.firstSymbolsSlots[droppable] == nil : self.secondSymbolsSlots[droppable] == nil)
        }) else {
            (set == .first ? self.firstSymbolsSlotsLock : self.secondSymbolsSlotsLock).signal()
            return
        }
        
        if set == .first {
            self.firstSymbolsSlots[onlyLeftDroppable] = onlyLeftSymbol
            self.firstMatchingSymbolsSet = []
        } else {
            self.secondSymbolsSlots[onlyLeftDroppable] = onlyLeftSymbol
            self.secondMatchingSymbolsSet = []
        }
        
        (set == .first ? self.firstSymbolsSlotsLock : self.secondSymbolsSlotsLock).signal()

        
        delegate.autocomplete(
            .init(
                draggable: onlyLeftSymbol,
                droppable: onlyLeftDroppable
            )
        )
        
        (set == .first ? self.firstMatchingSymbolsSetLock : self.secondMatchingSymbolsSetLock).signal()
    }

    
    private final func sortTilesIfPossible() {
        self.firstMatchingSymbolsSetLock.wait()
        self.secondMatchingSymbolsSetLock.wait()
        
        defer {
            self.secondMatchingSymbolsSetLock.signal()
            self.firstMatchingSymbolsSetLock.signal()
        }
        
        guard firstMatchingSymbolsSet.count <= 0 else { return }
        
        self.dropDestinationsOrderLock.wait()
        var copy = [DroppableIndex].init()
        
        for index in self.dropDestinationsOrder {
            copy.append(index)
        }
        
        self.delegateLock.wait()
        guard let delegate = self.delegate else {
            self.delegateLock.signal()
            return
        }
        
        self.firstSymbolsSlotsLock.wait()
        copy = copy.sorted { lhs, rhs in
            guard let lhsTile = self.firstSymbolsSlots[delegate.makeDroppableFor(index: lhs, side: .first)] else { return false }
            guard let rhsTile = self.firstSymbolsSlots[delegate.makeDroppableFor(index: rhs, side: .first)] else { return false }
            
            return delegate.priority(for: lhsTile) < delegate.priority(for: rhsTile)
        }
        
        self.delegateLock.signal()
        self.firstSymbolsSlotsLock.signal()
        
        self.dropDestinationsOrder = copy
        self.dropDestinationsOrderLock.signal()
    }
    
    public final func onDropEnded() {
        self.delegateLock.wait()
        guard let draggingEntity = self.draggingEntity else { return }
        guard let delegate = self.delegate else {
            self.delegateLock.signal()
            return
        }
        
        if self.validateDrop() {
            let droppedSymbolClass = delegate.classify(draggable: draggingEntity)
            (droppedSymbolClass == .first ? self.firstMatchingSymbolsSetLock : self.secondMatchingSymbolsSetLock).wait()
            
            if droppedSymbolClass == .first {
                self.firstMatchingSymbolsSet.removeAll { tile in
                    return tile == draggingEntity
                }
            } else {
                self.secondMatchingSymbolsSet.removeAll { tile in
                    return tile == draggingEntity
                }
            }
            
            (droppedSymbolClass == .first ? self.firstSymbolsSlotsLock : self.secondSymbolsSlotsLock).wait()
            
            self.lastCollidedDroppableLock.wait()
            guard let lastCollidedDroppable = self.lastCollidedDroppable else {
                self.lastCollidedDroppableLock.signal()
                return
            }
            
            if let previousSymbol = droppedSymbolClass == .first ?
                self.firstSymbolsSlots[lastCollidedDroppable] :
                    self.secondSymbolsSlots[lastCollidedDroppable]
            {
                if droppedSymbolClass == .first {
                    self.firstMatchingSymbolsSet.append(previousSymbol)
                } else {
                    self.secondMatchingSymbolsSet.append(previousSymbol)
                }
                
                delegate.revertSelection(draggingEntity)
            }
            
            if droppedSymbolClass == .first {
                self.firstSymbolsSlots[lastCollidedDroppable] = draggingEntity
            } else {
                self.secondSymbolsSlots[lastCollidedDroppable] = draggingEntity
            }
            self.lastCollidedDroppableLock.signal()
            
            (droppedSymbolClass == .first ? self.firstSymbolsSlotsLock : self.secondSymbolsSlotsLock).signal()
            (droppedSymbolClass == .first ? self.firstMatchingSymbolsSetLock : self.secondMatchingSymbolsSetLock).signal()
            
            self.delegateLock.signal()

            self.autocompleteSetIfPossible(delegate.classify(draggable: draggingEntity))
            self.sortTilesIfPossible()
        } else {
            self.delegateLock.signal()
        }
        
        self.draggingEntity = nil
    }
    
    
    
    // MARK: - GETTERS
    public final func isDragging() -> Bool {
        return self.draggingEntity != nil
    }
    
    public final func getDraggingEntity() -> Draggable? {
        return self.draggingEntity
    }

    public final func getDraggableIDFor(entity: Draggable) -> UUID {
        guard let id = self.tilesID[entity] else { fatalError("Attempted to get id for @unknown tile") }
        return id
    }
    
    public final func getSortedDroppableIndices() -> [DroppableIndex] {
        var copy = [DroppableIndex].init()
        
        self.dropDestinationsOrderLock.wait()
        for indexToCopy in self.dropDestinationsOrder {
            copy.append(indexToCopy)
        }
        self.dropDestinationsOrderLock.signal()
        
        return copy
    }
    
    public final func getSymbolForSlot(_ slot: Droppable) -> Draggable? {
        self.firstSymbolsSlotsLock.wait()
        if let theSymbol = self.firstSymbolsSlots[slot] {
            self.firstSymbolsSlotsLock.signal()
            return theSymbol
        } else {
            self.firstSymbolsSlotsLock.signal()
            self.secondSymbolsSlotsLock.wait()
            if let theSymbol = self.secondSymbolsSlots[slot] {
                self.secondSymbolsSlotsLock.signal()
                return theSymbol
            } else {
                self.secondSymbolsSlotsLock.signal()
                return nil
            }
        }
    }


    
    // MARK: - SETTERS
    public func setDelegate(_ delegate: any DragDropDelegate<Draggable, Droppable, DroppableIndex>) {
        self.delegateLock.wait()
        self.delegate = delegate
        self.delegateLock.signal()
    }
    
    
    public enum OnRegisterConflict {
        case replace
        case ignore
    }

}


fileprivate extension Array {
    func appending(contentsOf: Self) -> Self {
        var copy = Self.init()
        
        for element in self {
            copy.append(element)
        }
        
        for element in contentsOf {
            copy.append(element)
        }
        
        return copy
    }
}



public enum SymbolsSet: Sendable {
    case first
    case second
}
