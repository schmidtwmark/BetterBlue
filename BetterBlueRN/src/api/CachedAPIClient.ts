/**
 * Caching wrapper for any APIClient.
 *
 * - `fetchVehicleStatus` results are cached for 5 seconds per VIN.
 * - Concurrent identical requests are deduplicated: callers share the same
 *   in-flight promise rather than each issuing a separate network call.
 * - All other APIClient methods are forwarded to the delegate unchanged.
 */
import type {
  APIClient,
  EVTripDetail,
  MFAMethod,
  Vehicle,
  VehicleCommand,
  VehicleStatus,
} from './types';

const CACHE_TTL_MS = 5_000;

interface CacheEntry {
  status: VehicleStatus;
  expiresAt: number;
}

export class CachedAPIClient implements APIClient {
  private readonly delegate: APIClient;
  private readonly cache = new Map<string, CacheEntry>();
  private readonly pending = new Map<string, Promise<VehicleStatus>>();

  constructor(delegate: APIClient) {
    this.delegate = delegate;
  }

  // ── Passthrough methods ────────────────────────────────────────────────

  initialize = () => this.delegate.initialize();
  fetchVehicles = () => this.delegate.fetchVehicles();
  sendCommand = (v: Vehicle, c: VehicleCommand) => this.delegate.sendCommand(v, c);
  fetchEVTripDetails = (vin: string): Promise<EVTripDetail[] | null> =>
    this.delegate.fetchEVTripDetails?.(vin) ?? Promise.resolve(null);
  supportsMFA = () => this.delegate.supportsMFA();
  sendMFACode = (xid: string, otpKey: string, method: MFAMethod) =>
    this.delegate.sendMFACode(xid, otpKey, method);
  verifyMFACode = (xid: string, otpKey: string, code: string) =>
    this.delegate.verifyMFACode(xid, otpKey, code);
  completeMFALogin = (sid: string, rmToken: string) =>
    this.delegate.completeMFALogin(sid, rmToken);

  // ── Cached + deduplicated fetchVehicleStatus ───────────────────────────

  async fetchVehicleStatus(
    vin: string,
    regId: string,
    vehicleKey?: string,
    cached = true,
  ): Promise<VehicleStatus> {
    const cacheKey = `${vin}:${cached}`;
    const pendingKey = `${vin}:${cached}:pending`;

    // Serve from cache if within TTL (only when caller requested cached data)
    if (cached) {
      const entry = this.cache.get(cacheKey);
      if (entry && entry.expiresAt > Date.now()) {
        return entry.status;
      }
    }

    // Deduplicate: return in-flight promise if one exists
    const inFlight = this.pending.get(pendingKey);
    if (inFlight) return inFlight;

    const promise = this.delegate
      .fetchVehicleStatus(vin, regId, vehicleKey, cached)
      .then((status) => {
        this.cache.set(cacheKey, { status, expiresAt: Date.now() + CACHE_TTL_MS });
        this.pending.delete(pendingKey);
        return status;
      })
      .catch((err: unknown) => {
        this.pending.delete(pendingKey);
        throw err;
      });

    this.pending.set(pendingKey, promise);
    return promise;
  }

  /** Evict all cached status for a VIN (e.g. immediately after sending a command). */
  invalidate(vin: string): void {
    for (const key of this.cache.keys()) {
      if (key.startsWith(`${vin}:`)) this.cache.delete(key);
    }
  }
}
