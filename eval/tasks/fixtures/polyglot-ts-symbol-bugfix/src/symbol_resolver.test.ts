import { SymbolTable, formatSymbolSignature } from "./symbol_resolver";

export function runTests(): void {
  const table = new SymbolTable();
  table.register({ name: "login", kind: "function", namespace: "Auth", params: ["user", "pass"], returnType: "Promise<boolean>" });
  table.register({ name: "login", kind: "function", namespace: "Admin", params: ["token"], returnType: "boolean" });
  table.register({ name: "getUser", kind: "function", params: ["id"], returnType: "User" });

  if (table.size() !== 3) {
    throw new Error(`Expected size 3, got ${table.size()}`);
  }

  const authLogin = table.resolve("login", "Auth");
  if (!authLogin || authLogin.namespace !== "Auth") {
    throw new Error("Expected Auth.login");
  }

  if (table.resolve("get") !== undefined || table.size() !== 3) {
    throw new Error("Expected miss without substring collision or table mutation");
  }

  const sig = formatSymbolSignature(authLogin);
  if (sig !== "function Auth.login(user, pass): Promise<boolean>") {
    throw new Error(`Unexpected signature: ${sig}`);
  }
}
