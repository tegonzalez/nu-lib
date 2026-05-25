// Fixture: db.query namespace
// Used by cg matcher-based filter tests

export function run(sql: string): any[] {
  return execute(sql);
}

export function execute(sql: string): any[] {
  return [];
}
