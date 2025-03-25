import Foundation

public final class DragDropContext<Draggable: Hashable & Sendable, Droppable: DragDropEntity>: Sendable {
    private let draggable: Draggable
    private let droppable: Droppable
    
    public init(draggable: Draggable, droppable: Droppable) {
        self.draggable = draggable
        self.droppable = droppable
    }
    
    public func getDraggable() -> Draggable {
        return self.draggable
    }
    
    public func getDroppable() -> Droppable {
        return self.droppable
    }
}
