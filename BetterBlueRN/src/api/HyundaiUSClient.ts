/**
 * Hyundai USA API Client
 *
 * Implements the unofficial Hyundai BlueLink US API.
 * Reference: hyundai_kia_connect_api (Python), bluelinky (TypeScript)
 */
import type {
  APIClient,
  APIClientConfiguration,
  AuthToken,
  ClimateOptions,
  Distance,
  EVStatus,
  EVTripDetail,
  FuelRange,
  FuelType,
  HTTPLogEntry,
  LockStatus,
  MFAMethod,
  Vehicle,
  VehicleCommand,
  VehicleLocation,
  VehicleStatus,
} from './types';
import { APIError } from './types';

const BASE_URL = 'https://api.telematics.hyundaiusa.com';
const CLIENT_ID = 'm66129Bb-em93-SPAHYN-bZ91-am4540zp19920';
const CLIENT_SECRET = 'v558o935-6nne-423i-baa8';
const API_HOST = 'api.telematics.hyundaiusa.com';

function payloadTimestamp(): string {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, '0');
  return (
    String(d.getFullYear()) +
    p(d.getMonth() + 1) +
    p(d.getDate()) +
    p(d.getHours()) +
    p(d.getMinutes()) +
    p(d.getSeconds())
  );
}

function celsiusToFahrenheit(celsius: number): number {
  return Math.round((celsius * 9) / 5 + 32);
}

function extractNumber(value: unknown): number | undefined {
  if (typeof value === 'number') return value;
  if (typeof value === 'string') {
    const n = parseFloat(value);
    return isNaN(n) ? undefined : n;
  }
  return undefined;
}

export class HyundaiUSClient implements APIClient {
  private readonly config: APIClientConfiguration;
  private authToken: AuthToken | null = null;
  private vehicleCache = new Map<string, Vehicle>();

  constructor(config: APIClientConfiguration) {
    this.config = config;
  }

  async initialize(): Promise<void> {
    await this.ensureAuth();
  }

  // ── Auth ──────────────────────────────────────────────────────────────

  private async ensureAuth(): Promise<AuthToken> {
    if (this.authToken && this.authToken.expiresAt > Date.now() + 60_000) {
      return this.authToken;
    }
    if (this.authToken?.refreshToken) {
      try {
        return await this.refreshAuthToken(this.authToken.refreshToken);
      } catch {
        // fall through to full re-login
      }
    }
    return this.login();
  }

  private async login(): Promise<AuthToken> {
    const resp = await this.loggedFetch(
      `${BASE_URL}/v2/ac/oauth/token`,
      {
        method: 'POST',
        headers: this.baseHeaders(),
        body: JSON.stringify({
          username: this.config.username,
          password: this.config.password,
        }),
      },
      'login',
    );
    const json = (await resp.json()) as Record<string, unknown>;
    if (!json.access_token) {
      throw new APIError('Invalid login response', 'invalidCredentials');
    }
    const token: AuthToken = {
      accessToken: json.access_token as string,
      refreshToken: json.refresh_token as string | undefined,
      expiresAt:
        Date.now() + parseInt(json.expires_in as string, 10) * 1000,
    };
    this.authToken = token;
    return token;
  }

  private async refreshAuthToken(refreshToken: string): Promise<AuthToken> {
    const resp = await this.loggedFetch(
      `${BASE_URL}/v2/ac/oauth/token/refresh`,
      {
        method: 'POST',
        headers: this.baseHeaders(),
        body: JSON.stringify({ refresh_token: refreshToken }),
      },
      'refreshToken',
    );
    const json = (await resp.json()) as Record<string, unknown>;
    if (!json.access_token) throw new APIError('Refresh failed', 'invalidCredentials');
    const token: AuthToken = {
      accessToken: json.access_token as string,
      refreshToken: json.refresh_token as string | undefined,
      expiresAt:
        Date.now() + parseInt(json.expires_in as string, 10) * 1000,
    };
    this.authToken = token;
    return token;
  }

  // ── Vehicles ──────────────────────────────────────────────────────────

  async fetchVehicles(): Promise<Vehicle[]> {
    const auth = await this.ensureAuth();
    const resp = await this.loggedFetch(
      `${BASE_URL}/ac/v2/enrollment/details/${this.config.username}`,
      { method: 'GET', headers: this.authorizedHeaders(auth) },
      'fetchVehicles',
    );
    const json = (await resp.json()) as Record<string, unknown>;
    const enrolled = (json.enrolledVehicleDetails ?? []) as Record<string, unknown>[];
    const vehicles: Vehicle[] = enrolled.flatMap((entry) => {
      const details = entry.vehicleDetails as Record<string, unknown> | undefined;
      if (!details) return [];
      const vin = details.vin as string | undefined;
      const regId = details.regid as string | undefined;
      if (!vin || !regId) return [];
      const evStatus = details.evStatus as string | undefined;
      const fuelType: FuelType =
        evStatus === 'E' ? 'electric' : evStatus === 'P' ? 'phev' : 'gas';
      const odometerRaw = extractNumber(details.odometer);
      const vehicle: Vehicle = {
        id: vin,
        vin,
        regId,
        model: (details.nickName as string | undefined) ?? vin,
        accountId: this.config.accountId,
        fuelType,
        generation: parseInt((details.vehicleGeneration as string | undefined) ?? '2', 10),
        isHidden: false,
        sortOrder: 0,
        backgroundColorName: 'default',
        chargePortType: 'CCS1',
        enableSeatHeatControls: false,
        odometer: odometerRaw != null ? { length: odometerRaw, units: 'miles' } : undefined,
      };
      return [vehicle];
    });
    vehicles.forEach((v) => this.vehicleCache.set(v.vin, v));
    return vehicles;
  }

  // ── Vehicle Status ────────────────────────────────────────────────────

  async fetchVehicleStatus(
    vin: string,
    regId: string,
    _vehicleKey?: string,
    cached = true,
  ): Promise<VehicleStatus> {
    const auth = await this.ensureAuth();
    const vehicle = this.vehicleCache.get(vin);
    const resp = await this.loggedFetch(
      `${BASE_URL}/ac/v2/rcs/rvs/vehicleStatus`,
      {
        method: 'GET',
        headers: this.authorizedHeaders(
          auth,
          vehicle ?? { vin, regId, generation: 2 },
          /* refresh */ !cached,
        ),
      },
      'fetchVehicleStatus',
    );
    const json = (await resp.json()) as Record<string, unknown>;
    const s = (json.vehicleStatus ?? {}) as Record<string, unknown>;
    return this.parseVehicleStatus(s, vehicle);
  }

  // ── Commands ──────────────────────────────────────────────────────────

  async sendCommand(vehicle: Vehicle, command: VehicleCommand): Promise<void> {
    const auth = await this.ensureAuth();
    const url = this.commandURL(command, vehicle);
    const body = this.commandBody(command, vehicle);
    const bodyStr = Object.keys(body).length > 0 ? JSON.stringify(body) : undefined;
    const resp = await this.loggedFetch(
      url,
      {
        method: 'POST',
        headers: this.authorizedHeaders(auth, vehicle),
        body: bodyStr,
      },
      'sendCommand',
    );
    const json = (await resp.json().catch(() => ({}))) as Record<string, unknown>;
    if (json.isBlueLinkServicePinValid === 'invalid') {
      throw new APIError('Invalid PIN', 'invalidPin');
    }
  }

  // ── EV Trip Details ───────────────────────────────────────────────────

  async fetchEVTripDetails(vin: string): Promise<EVTripDetail[] | null> {
    const auth = await this.ensureAuth();
    const vehicle = this.vehicleCache.get(vin);
    if (!vehicle) return null;
    const headers = {
      ...this.authorizedHeaders(auth, vehicle),
      userId: this.config.username,
      access_token: auth.accessToken,
    };
    try {
      const resp = await this.loggedFetch(
        `${BASE_URL}/ac/v2/ts/alerts/maintenance/evTripDetails`,
        { method: 'GET', headers },
        'fetchEVTripDetails',
      );
      const json = (await resp.json()) as Record<string, unknown>;
      return this.parseTripDetails(json);
    } catch {
      return null;
    }
  }

  // ── MFA (not supported) ───────────────────────────────────────────────

  supportsMFA(): boolean {
    return false;
  }

  async sendMFACode(_xid: string, _otpKey: string, _method: MFAMethod): Promise<void> {
    throw new APIError('MFA not supported by Hyundai US', 'general');
  }

  async verifyMFACode(
    _xid: string,
    _otpKey: string,
    _code: string,
  ): Promise<{ rememberMeToken: string; sid: string }> {
    throw new APIError('MFA not supported by Hyundai US', 'general');
  }

  async completeMFALogin(_sid: string, _rmToken: string): Promise<void> {
    throw new APIError('MFA not supported by Hyundai US', 'general');
  }

  // ── Private Helpers ───────────────────────────────────────────────────

  private baseHeaders(): Record<string, string> {
    return {
      client_id: CLIENT_ID,
      clientSecret: CLIENT_SECRET,
      Host: API_HOST,
      'User-Agent': 'okhttp/3.12.0',
      'Content-Type': 'application/json',
      Accept: 'application/json, text/plain, */*',
    };
  }

  private authorizedHeaders(
    auth: AuthToken,
    vehicle?: Pick<Vehicle, 'vin' | 'regId' | 'generation'>,
    refresh = false,
  ): Record<string, string> {
    const headers: Record<string, string> = {
      ...this.baseHeaders(),
      accessToken: auth.accessToken,
      language: '0',
      to: 'ISS',
      encryptFlag: 'false',
      from: 'SPA',
      offset: '-5',
      brandIndicator: 'H',
      origin: `https://${API_HOST}`,
      referer: `https://${API_HOST}/login`,
      username: this.config.username,
      blueLinkServicePin: this.config.pin,
      refresh: refresh ? 'true' : 'false',
      payloadGenerated: payloadTimestamp(),
      includeNonConnectedVehicles: 'Y',
    };
    if (vehicle) {
      headers.gen = String(vehicle.generation ?? 2);
      headers.registrationId = vehicle.regId;
      headers.vin = vehicle.vin;
      headers['APPCLOUD-VIN'] = vehicle.vin;
    }
    return headers;
  }

  private commandURL(command: VehicleCommand, vehicle: Vehicle): string {
    const isEV = vehicle.fuelType === 'electric' || vehicle.fuelType === 'phev';
    switch (command.type) {
      case 'unlock':       return `${BASE_URL}/ac/v2/rcs/rdo/on`;
      case 'lock':         return `${BASE_URL}/ac/v2/rcs/rdo/off`;
      case 'startClimate': return isEV ? `${BASE_URL}/ac/v2/evc/fatc/start` : `${BASE_URL}/ac/v2/rcs/rsc/start`;
      case 'stopClimate':  return isEV ? `${BASE_URL}/ac/v2/evc/fatc/stop`  : `${BASE_URL}/ac/v2/rcs/rsc/stop`;
      case 'startCharge':  return `${BASE_URL}/ac/v2/evc/charge/start`;
      case 'stopCharge':   return `${BASE_URL}/ac/v2/evc/charge/stop`;
      case 'setTargetSOC': return `${BASE_URL}/ac/v2/evc/charge/targetsoc/set`;
    }
  }

  private commandBody(
    command: VehicleCommand,
    vehicle: Vehicle,
  ): Record<string, unknown> {
    if (command.type === 'startClimate') {
      const opts = command.options;
      const fahrenheit = celsiusToFahrenheit(opts.temperature);
      const isEV = vehicle.fuelType === 'electric' || vehicle.fuelType === 'phev';
      if (isEV) {
        const body: Record<string, unknown> = {
          airCtrl: opts.heating ? 1 : 0,
          airTemp: { value: String(fahrenheit), unit: 1 },
          defrost: opts.defrost,
          heating1: opts.heating ? 1 : 0,
        };
        if (vehicle.generation >= 3) {
          body.igniOnDuration = opts.duration;
          body.seatHeaterVentInfo = this.seatHeaterInfo(opts);
        }
        return body;
      }
      return {
        Ims: 0,
        airCtrl: opts.heating ? 1 : 0,
        airTemp: { unit: 1, value: fahrenheit },
        defrost: opts.defrost,
        heating1: opts.heating ? 1 : 0,
        igniOnDuration: opts.duration,
        seatHeaterVentInfo: this.seatHeaterInfo(opts),
        username: this.config.username,
        vin: vehicle.vin,
      };
    }
    if (command.type === 'setTargetSOC') {
      return {
        targetSOClist: [
          { targetSOClevel: command.acLevel, plugType: 1 },
          { targetSOClevel: command.dcLevel, plugType: 0 },
        ],
      };
    }
    return {};
  }

  private seatHeaterInfo(opts: ClimateOptions): Record<string, number> {
    return {
      driverSeat: opts.frontLeftSeatHeat,
      passengerSeat: opts.frontRightSeatHeat,
      rearLeftSeat: 0,
      rearRightSeat: 0,
    };
  }

  // ── Response Parsing ──────────────────────────────────────────────────

  private parseVehicleStatus(
    s: Record<string, unknown>,
    vehicle?: Vehicle,
  ): VehicleStatus {
    return {
      lastUpdated: Date.now(),
      syncDate: this.parseSyncDate(s),
      lockStatus: this.parseLockStatus(s),
      climateStatus: this.parseClimateStatus(s),
      evStatus: this.parseEVStatus(s, vehicle?.fuelType),
      gasRange: this.parseGasRange(s, vehicle?.fuelType),
      location: this.parseLocation(s),
      battery12V: this.parseBattery12V(s),
      doorOpen: this.parseDoorOpen(s),
      trunkOpen: s.trunkOpen as boolean | undefined,
      hoodOpen: s.hoodOpen as boolean | undefined,
    };
  }

  private parseLockStatus(s: Record<string, unknown>): LockStatus {
    return { locked: (s.doorLock as boolean | undefined) ?? false };
  }

  private parseClimateStatus(s: Record<string, unknown>) {
    const airTemp = (s.airTemp ?? {}) as Record<string, unknown>;
    return {
      airControlOn: (s.airCtrlOn as boolean | undefined) ?? false,
      defrostOn: (s.defrost as boolean | undefined) ?? false,
      temperature: airTemp.value != null
        ? parseFloat(airTemp.value as string)
        : undefined,
    };
  }

  private parseEVStatus(
    s: Record<string, unknown>,
    fuelType?: FuelType,
  ): EVStatus | undefined {
    if (fuelType === 'gas') return undefined;
    const ev = (s.evStatus ?? {}) as Record<string, unknown>;
    const batteryLevel = extractNumber(ev.batteryStatus);
    if (batteryLevel == null) return undefined;

    const drvDistances = (ev.drvDistance ?? []) as Record<string, unknown>[];
    let range: Distance = { length: 0, units: 'miles' };
    for (const d of drvDistances) {
      const rbf = (d.rangeByFuel ?? {}) as Record<string, unknown>;
      const evMode = ((rbf.evModeRange ?? rbf.totalAvailableRange) ?? {}) as Record<string, unknown>;
      const val = extractNumber(evMode.value);
      if (val != null) {
        range = { length: val, units: extractNumber(evMode.unit) === 3 ? 'miles' : 'km' };
        break;
      }
    }

    const remainTime2 = (ev.remainTime2 ?? {}) as Record<string, unknown>;
    const atc = (remainTime2.atc ?? {}) as Record<string, unknown>;
    const chargeMinutes = extractNumber(atc.value) ?? 0;
    const batteryPlugin = extractNumber(ev.batteryPlugin) ?? 0;
    const isCharging = (ev.batteryCharge as boolean | undefined) ?? false;

    const targetSocList = (
      ((ev.reservChargeInfos as Record<string, unknown> | undefined) ?? {})
        .targetSOClist ?? []
    ) as Record<string, unknown>[];
    let acTargetSOC: number | undefined;
    let dcTargetSOC: number | undefined;
    for (const t of targetSocList) {
      const pt = extractNumber(t.plugType);
      const soc = extractNumber(t.targetSOClevel);
      if (pt === 1) acTargetSOC = soc;
      else if (pt === 0) dcTargetSOC = soc;
    }

    return {
      batteryLevel,
      range,
      chargeStatus: isCharging ? 'charging' : 'not_charging',
      isCharging,
      isPluggedIn: batteryPlugin > 0,
      chargeRemainingMinutes: chargeMinutes,
      plugType: batteryPlugin === 0 ? 'unplugged' : batteryPlugin === 2 ? 'dc' : 'ac',
      acTargetSOC,
      dcTargetSOC,
    };
  }

  private parseGasRange(
    s: Record<string, unknown>,
    fuelType?: FuelType,
  ): FuelRange | undefined {
    if (fuelType === 'electric') return undefined;
    const fuelLevel = extractNumber(s.fuelLevel);
    if (fuelLevel == null) return undefined;
    const dte = (s.dte ?? {}) as Record<string, unknown>;
    const val = extractNumber(dte.value);
    if (val == null) return undefined;
    return {
      range: { length: val, units: extractNumber(dte.unit) === 3 ? 'miles' : 'km' },
      fuelLevel,
    };
  }

  private parseLocation(s: Record<string, unknown>): VehicleLocation | undefined {
    const loc = (s.vehicleLocation ?? {}) as Record<string, unknown>;
    const coord = (loc.coord ?? {}) as Record<string, unknown>;
    const lat = extractNumber(coord.lat);
    const lon = extractNumber(coord.lon);
    if (lat == null || lon == null) return undefined;
    return { latitude: lat, longitude: lon };
  }

  private parseDoorOpen(s: Record<string, unknown>) {
    const d = (s.doorOpen ?? {}) as Record<string, unknown>;
    return {
      frontLeft: (extractNumber(d.frontLeft) ?? 0) !== 0,
      frontRight: (extractNumber(d.frontRight) ?? 0) !== 0,
      rearLeft: (extractNumber(d.backLeft) ?? 0) !== 0,
      rearRight: (extractNumber(d.backRight) ?? 0) !== 0,
    };
  }

  private parseBattery12V(s: Record<string, unknown>): number | undefined {
    const bat = (s.battery ?? {}) as Record<string, unknown>;
    return extractNumber(bat.batSoc);
  }

  private parseSyncDate(s: Record<string, unknown>): number | undefined {
    const dt = s.dateTime as string | undefined;
    if (!dt) return undefined;
    const d = new Date(dt);
    return isNaN(d.getTime()) ? undefined : d.getTime();
  }

  private parseTripDetails(json: Record<string, unknown>): EVTripDetail[] {
    const trips = (json.tripdetails ?? []) as Record<string, unknown>[];
    return trips.map((t, i) => ({
      tripId: String(i),
      date: Date.now(),
      distance: { length: extractNumber(t.distance) ?? 0, units: 'miles' as const },
      energyUsed: extractNumber(t.totalused) ?? 0,
    }));
  }

  // ── HTTP Helper ───────────────────────────────────────────────────────

  private async loggedFetch(
    url: string,
    init: RequestInit,
    type: string,
  ): Promise<Response> {
    const start = Date.now();
    const logId = Math.random().toString(36).slice(2);
    const reqHeaders = (init.headers ?? {}) as Record<string, string>;
    try {
      const response = await fetch(url, init);
      const text = await response.text();
      const durationMs = Date.now() - start;
      const log: HTTPLogEntry = {
        id: logId,
        accountId: this.config.accountId,
        timestamp: start,
        method: (init.method ?? 'GET').toUpperCase(),
        url,
        requestHeaders: reqHeaders,
        requestBody: init.body != null ? String(init.body) : undefined,
        responseStatus: response.status,
        responseBody: text,
        durationMs,
      };
      this.config.onHTTPLog?.(log);
      if (!response.ok) {
        let errMsg = `HTTP ${response.status}`;
        try {
          const body = JSON.parse(text) as Record<string, unknown>;
          errMsg = (body.message ?? body.error ?? errMsg) as string;
        } catch { /* ignore */ }
        throw new APIError(errMsg, 'serverError');
      }
      return new Response(text, { status: response.status, headers: response.headers });
    } catch (err) {
      if (err instanceof APIError) throw err;
      this.config.onHTTPLog?.({
        id: logId,
        accountId: this.config.accountId,
        timestamp: start,
        method: (init.method ?? 'GET').toUpperCase(),
        url,
        error: String(err),
        durationMs: Date.now() - start,
      });
      throw new APIError(String(err), 'serverError', err);
    }
  }
}
