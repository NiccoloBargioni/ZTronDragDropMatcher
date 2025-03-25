import Foundation

class Stack<T: Any> {
    private var nodes: [T]
    
    init() {
        self.nodes = []
    }
    
    func isEmpty() -> Bool {
        return nodes.count == 0
    }
    
    func push(node: T) {
        nodes.append(node)
    }
    
    func pop() -> T? {
        return self.nodes.popLast()
    }
    
    func peek() -> T? {
        return self.nodes.last
    }
    
    func count() -> Int {
        return self.nodes.count
    }
    
}
