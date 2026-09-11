// Validates a handoff file against the subset of JSON Schema the pipeline uses.
//
// Deliberately not a full JSON Schema implementation and deliberately without a
// dependency: the schemas in schemas/ are read by two audiences -- the agent, as
// part of its prompt, and this file, as the gate -- and a validator small enough
// to read in one sitting is what keeps those two from drifting apart. Supports
// exactly: type, properties, required, enum, items, additionalProperties:false,
// minLength. Anything else in a schema is ignored, so do not reach for it.
//
// Usage:  node validate.mjs <schema.json> <instance.json>
// Exit:   0 valid, 1 invalid (reasons on stdout), 2 the invocation is broken.

import { readFileSync } from "node:fs";

const [schemaPath, instancePath] = process.argv.slice(2);
if (!schemaPath || !instancePath) {
  console.error("usage: validate.mjs <schema.json> <instance.json>");
  process.exit(2);
}

const readJson = (path, role) => {
  let text;
  try {
    text = readFileSync(path, "utf8");
  } catch (err) {
    console.error(`cannot read ${role} ${path}: ${err.message}`);
    process.exit(2);
  }
  try {
    return JSON.parse(text);
  } catch (err) {
    // An unparseable instance is the agent's fault, not the invocation's, so it
    // is a validation failure (1) rather than a broken call (2). The driver
    // retries a 1 and aborts on a 2.
    if (role === "instance") {
      console.log(`not valid JSON: ${err.message}`);
      process.exit(1);
    }
    console.error(`schema ${path} is not valid JSON: ${err.message}`);
    process.exit(2);
  }
};

const schema = readJson(schemaPath, "schema");
const instance = readJson(instancePath, "instance");
const errors = [];

const typeOf = (value) =>
  value === null ? "null" : Array.isArray(value) ? "array" : typeof value;

const check = (node, value, path) => {
  const where = path || "(root)";

  if (node.type) {
    const actual = typeOf(value);
    const ok =
      node.type === "integer"
        ? actual === "number" && Number.isInteger(value)
        : node.type === actual;
    if (!ok) {
      errors.push(`${where}: expected ${node.type}, got ${actual}`);
      return; // Everything below assumes the type held.
    }
  }

  if (node.enum && !node.enum.includes(value)) {
    errors.push(`${where}: ${JSON.stringify(value)} is not one of ${node.enum.join(", ")}`);
  }

  if (node.minLength !== undefined && typeof value === "string" && value.length < node.minLength) {
    errors.push(`${where}: must be at least ${node.minLength} character(s)`);
  }

  if (typeOf(value) === "object") {
    for (const key of node.required ?? []) {
      if (!(key in value)) errors.push(`${where}: missing required field "${key}"`);
    }
    const properties = node.properties ?? {};
    if (node.additionalProperties === false) {
      for (const key of Object.keys(value)) {
        if (!(key in properties)) errors.push(`${where}: unexpected field "${key}"`);
      }
    }
    for (const [key, subSchema] of Object.entries(properties)) {
      if (key in value) check(subSchema, value[key], path ? `${path}.${key}` : key);
    }
  }

  if (typeOf(value) === "array" && node.items) {
    value.forEach((item, i) => check(node.items, item, `${where}[${i}]`));
  }
};

check(schema, instance, "");

if (errors.length > 0) {
  for (const error of errors) console.log(error);
  process.exit(1);
}
process.exit(0);
