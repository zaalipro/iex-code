export interface SymbolEntry {
  name: string;
  kind: "function" | "class" | "interface" | "type" | "method";
  namespace?: string;
  params?: string[];
  returnType?: string;
}

export class SymbolTable {
  private entries: Map<string, SymbolEntry> = new Map();

  register(entry: SymbolEntry): void {
    // BUG 1: ignores namespace when building key, causing collisions across namespaces
    const key = entry.name;
    this.entries.set(key, entry);
  }

  resolve(name: string, namespace?: string): SymbolEntry | undefined {
    // BUG 2: substring match (`includes`) causes false-positive collisions ("get" matching "getUser"),
    // and inserts a placeholder entry when missing instead of returning undefined cleanly.
    const target = namespace ? `${namespace}.${name}` : name;

    for (const [key, value] of this.entries.entries()) {
      if (key.includes(target)) {
        return value;
      }
    }

    this.entries.set(target, { name, kind: "function", namespace });
    return undefined;
  }

  size(): number {
    return this.entries.size;
  }
}

export function formatSymbolSignature(entry: SymbolEntry): string {
  // BUG 3: drops namespace prefix, drops params after the first, and formats returnType with "->" instead of ": "
  const params = entry.params ? (entry.params[0] ?? "") : "";
  const ret = entry.returnType ? ` -> ${entry.returnType}` : "";
  return `${entry.kind} ${entry.name}(${params})${ret}`;
}
