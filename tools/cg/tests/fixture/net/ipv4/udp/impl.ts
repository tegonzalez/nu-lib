// Fixture: net.ipv4.udp namespace
// Used by cg matcher-based filter tests

export function send(data: Buffer, host: string): number {
  return socket(host);
}

export function socket(host: string): number {
  return 0;
}
