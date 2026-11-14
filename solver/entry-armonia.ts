import main from "./src/yt/solver/main.ts";
// Punto d'ingresso per JavaScriptCore: riceve e restituisce JSON come testo.
(globalThis as any).armoniaSolve = (input: string): string => JSON.stringify(main(JSON.parse(input)));
