// Fixture: net.ipv4.tcp namespace
// Used by cg matcher-based filter tests

export function connect(host: string, port: number): boolean {
  return dial(host, port);
}

export function dial(host: string, port: number): boolean {
  return true;
}
