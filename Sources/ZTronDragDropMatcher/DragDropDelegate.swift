import Foundation

public protocol DragDropDelegate<Draggable, Droppable, DroppableIndex>: Sendable {
    associatedtype Draggable: Hashable & Sendable
    associatedtype Droppable: DragDropEntity
    associatedtype DroppableIndex: Hashable
    
    func onDragUpdated(_ info: DragDropContext<Draggable, Droppable>)
    func validateDrop(_ info: DragDropContext<Draggable, Droppable>) -> Bool
    func transformDrop(_ info: DragDropContext<Draggable, Droppable>) -> Droppable
    func autocomplete(_ info: DragDropContext<Draggable, Droppable>)
    
    func priority(for draggable: Draggable) -> Int
    func classify(draggable: Draggable) -> SymbolsSet
    func classify(droppable: Droppable) -> SymbolsSet
    func revertSelection(_ draggable: Draggable)
    func makeDroppableFor(index: DroppableIndex, side: SymbolsSet) -> Droppable
}
