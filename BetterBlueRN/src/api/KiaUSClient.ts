/**
 * Kia USA API Client
 *
 * Implements the unofficial Kia Connect US API with MFA support.
 * Reference: hyundai_kia_connect_api (Python), bluelinky (TypeScript)
 *
 * Key characteristics:
 * - Session-based auth (23-hour lifetime); session ID lives in response header `sid`
 * - Device ID is a stable uppercase UUID; clientUUID is UUID5 of deviceId
 * - MFA triggered when `payload.otpKey` appears in login response
 * - Real-time status refresh via `rems/rvs` before cached `cmm/gvi`
 */
import type {
  APIClient,
  APIClientConfiguration,
  AuthToken,
  Distance,
  EVStatus,
  EVTripDetail,
  FuelRange,
  FuelType,
  HTTPLogEntry,
  MFAInfo,
  MFAMethod,
  Vehicle,
  VehicleCommand,
  VehicleLocation,
  VehicleStatus,
} from './types';
import { APIError } from './types';

const BASE_URL = 'https://api.owners.kia.com';
const LOGIN_TOKEN_LIFETIME_MS = 23 * 3600 * 1000;
const DNS_NAMESPACE = '6ba7b810-9dad-11d1-80b4-00c04fd430c8';

// ── UUID5 helper ─────────────────────────────────────────────────────────────

function uuidToBytes(uuid: string): Uint8Array {
  const hex = uuid.replace(/-/g, '');
  const bytes = new Uint8Array(16);
  for (let i = 0; i < 16; i++) bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return bytes;
}

function bytesToUUID(b: Uint8Array): string {
  const h = Array.from(b).map((x) => x.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

async function generateUUID5(namespace: string, name: string): Promise<string> {
  const nsBytes = uuidToBytes(namespace);
  const nameBytes = new TextEncoder().encode(name);
  const data = new Uint8Array(nsBytes.length + nameBytes.length);
  data.set(nsBytes);
  data.set(nameBytes, nsBytes.length);
  const hashBuf = await crypto.subtle.digest('SHA-1', data);
  const hash = new Uint8Array(hashBuf);
  hash[6] = (hash[6] & 0x0f) | 0x50; // version 5
  hash[8] = (hash[8] & 0x3f) | 0x80; // variant
  return bytesToUUID(hash.slice(0, 16));
}

// ── Number extraction helper ──────────────────────────────────────────────────

function extractNumber(value: unknown): number | undefined {
  if (typeof value === 'number') return value;
  if (typeof value === 'string') {
    const n = parseFloat(value);
    return isNaN(n) ? undefined : n;
  }
  return undefined;
}

function isJSONBoolean(value: unknown): boolean {
  return value === true || value === false;
}

// ── Temperature helper (Kia US always expects Fahrenheit, 62–82°F range) ──────

function kiaUSAirTemp(celsius: number): { value: string; unit: 1 } {
  const fahrenheit = Math.round((celsius * 9) / 5 + 32);
  let value: string;
  if (fahrenheit < 62) value = 'LOW';
  else if (fahrenheit > 82) value = 'HIGH';
  else value = String(fahrenheit);
  return { value, unit: 1 };
}

// ── Client ────────────────────────────────────────────────────────────────────

export class KiaUSClient implements APIClient {
  private readonly config: APIClientConfiguration;
  private readonly deviceId: string;
  private clientUUID = '';
  private authToken: AuthToken | null = null;
  private vehicleCache = new Map<string, Vehicle>();

  constructor(config: APIClientConfiguration) {
    this.config = config;
    this.deviceId = config.deviceId ?? crypto.randomUUID().toUpperCase();
  }

  async initialize(): Promise<void> {
    this.clientUUID = await generateUUID5(DNS_NAMESPACE, this.deviceId);
    await this.ensureAuth();
  }

  // ── Auth ────────────────────────────────────────────────────────────────

  private get apiURL(): string {
    return `${BASE_URL}/apigw/v1/`;
  }

  private async ensureAuth(): Promise<AuthToken> {
    if (this.authToken && this.authToken.expiresAt > Date.now() + 60_000) {
      return this.authToken;
    }
    return this.login();
  }

  private async login(): Promise<AuthToken> {
    return this.loginWithMFA(undefined, this.config.rememberMeToken);
  }

  private async loginWithMFA(
    sid: string | undefined,
    rmToken: string | undefined,
  ): Promise<AuthToken> {
    const headers: Record<string, string> = { ...this.baseHeaders() };
    if (rmToken) headers.rmtoken = rmToken;
    if (sid) headers.sid = sid;

    const body = {
      deviceKey: this.deviceId,
      deviceType: 2,
      tncFlag: 1,
      userCredential: {
        userId: this.config.username,
        password: this.config.password,
      },
    };

    const { text, responseHeaders } = await this.loggedFetchRaw(
      `${this.apiURL}prof/authUser`,
      { method: 'POST', headers, body: JSON.stringify(body) },
      'login',
    );

    const json = JSON.parse(text) as Record<string, unknown>;
    this.checkForKiaErrors(json);

    // Check for MFA requirement
    const payload = json.payload as Record<string, unknown> | undefined;
    if (payload?.otpKey) {
      const xid = responseHeaders.xid ?? responseHeaders.Xid ?? responseHeaders.XID ?? '';
      const mfaInfo: MFAInfo = {
        xid,
        otpKey: payload.otpKey as string,
        email: payload.email as string | undefined,
        phone: payload.phone as string | undefined,
      };
      throw new APIError('MFA required', 'requiresMFA', undefined, mfaInfo);
    }

    const sessionId =
      responseHeaders.sid ?? responseHeaders.Sid ?? responseHeaders.SID;
    if (!sessionId) {
      throw new APIError('Login response missing session ID header', 'serverError');
    }

    // Check for rotated rmToken
    const rotatedRmToken =
      responseHeaders.rmToken ?? responseHeaders.rmtoken ?? responseHeaders.RmToken;
    if (rotatedRmToken) {
      this.config.onRememberMeTokenRotated?.(rotatedRmToken);
    }

    const token: AuthToken = {
      accessToken: sessionId,
      refreshToken: sessionId,
      expiresAt: Date.now() + LOGIN_TOKEN_LIFETIME_MS,
    };
    this.authToken = token;
    return token;
  }

  supportsMFA(): boolean {
    return true;
  }

  async sendMFACode(xid: string, otpKey: string, method: MFAMethod): Promise<void> {
    const headers: Record<string, string> = {
      ...this.baseHeaders(),
      otpkey: otpKey,
      notifytype: method === 'email' ? 'EMAIL' : 'SMS',
      xid,
    };
    const { text } = await this.loggedFetchRaw(
      `${this.apiURL}cmm/sendOTP`,
      { method: 'POST', headers, body: JSON.stringify({}) },
      'sendMFA',
    );
    this.checkForKiaErrors(JSON.parse(text) as Record<string, unknown>);
  }

  async verifyMFACode(
    xid: string,
    otpKey: string,
    code: string,
  ): Promise<{ rememberMeToken: string; sid: string }> {
    const headers: Record<string, string> = {
      ...this.baseHeaders(),
      otpkey: otpKey,
      xid,
    };
    const { text, responseHeaders } = await this.loggedFetchRaw(
      `${this.apiURL}cmm/verifyOTP`,
      { method: 'POST', headers, body: JSON.stringify({ otp: code }) },
      'verifyMFA',
    );
    this.checkForKiaErrors(JSON.parse(text) as Record<string, unknown>);
    const rmToken =
      responseHeaders.rmToken ?? responseHeaders.rmtoken ?? responseHeaders.RmToken;
    const sid = responseHeaders.sid ?? responseHeaders.Sid ?? responseHeaders.SID;
    if (!rmToken || !sid) {
      throw new APIError('Verify OTP response missing tokens', 'serverError');
    }
    return { rememberMeToken: rmToken, sid };
  }

  async completeMFALogin(sid: string, rmToken: string): Promise<void> {
    await this.loginWithMFA(sid, rmToken);
  }

  // ── Vehicles ────────────────────────────────────────────────────────────

  async fetchVehicles(): Promise<Vehicle[]> {
    const auth = await this.ensureAuth();
    const { text } = await this.loggedFetchRaw(
      `${this.apiURL}ownr/gvl`,
      { method: 'GET', headers: this.authorizedHeaders(auth) },
      'fetchVehicles',
    );
    const json = JSON.parse(text) as Record<string, unknown>;
    this.checkForKiaErrors(json);
    const payload = (json.payload ?? {}) as Record<string, unknown>;
    const summary = (payload.vehicleSummary ?? []) as Record<string, unknown>[];
    const vehicles: Vehicle[] = summary.flatMap((entry) => {
      const vin = entry.vin as string | undefined;
      const regId = entry.vehicleIdentifier as string | undefined;
      const vehicleKey = entry.vehicleKey as string | undefined;
      const fuelTypeNum = extractNumber(entry.fuelType);
      if (!vin || !regId || !vehicleKey || fuelTypeNum == null) return [];
      const fuelType: FuelType = fuelTypeNum === 4 ? 'electric' : 'gas';
      const vehicle: Vehicle = {
        id: vin,
        vin,
        regId,
        model: (entry.nickName as string | undefined) ?? vin,
        accountId: this.config.accountId,
        fuelType,
        generation: parseInt((entry.genType as string | undefined) ?? '2', 10),
        vehicleKey,
        isHidden: false,
        sortOrder: 0,
        backgroundColorName: 'default',
        chargePortType: 'CCS1',
        enableSeatHeatControls: false,
        odometer: extractNumber(entry.mileage) != null
          ? { length: extractNumber(entry.mileage)!, units: 'miles' }
          : undefined,
      };
      return [vehicle];
    });
    vehicles.forEach((v) => this.vehicleCache.set(v.vin, v));
    return vehicles;
  }

  // ── Vehicle Status ────────────────────────────────────────────────────────

  async fetchVehicleStatus(
    vin: string,
    _regId: string,
    vehicleKey?: string,
    cached = true,
  ): Promise<VehicleStatus> {
    const auth = await this.ensureAuth();
    const vehicle = this.vehicleCache.get(vin);
    const vKey = vehicleKey ?? vehicle?.vehicleKey;

    if (!cached) {
      await this.triggerRealTimeRefresh(auth, vKey);
    }

    const reqBody = {
      vehicleConfigReq: {
        airTempRange: '0', maintenance: '1', seatHeatCoolOption: '0',
        vehicle: '1', vehicleFeature: '0',
      },
      vehicleInfoReq: {
        drivingActivty: '0', dtc: '1', enrollment: '1', functionalCards: '0',
        location: '1', vehicleStatus: '1', weather: '0',
      },
      vinKey: [vKey ?? ''],
    };

    const { text } = await this.loggedFetchRaw(
      `${this.apiURL}cmm/gvi`,
      {
        method: 'POST',
        headers: this.authorizedHeaders(auth, vKey),
        body: JSON.stringify(reqBody),
      },
      'fetchVehicleStatus',
    );
    const json = JSON.parse(text) as Record<string, unknown>;
    this.checkForKiaErrors(json);
    return this.parseVehicleStatus(json, vehicle);
  }

  private async triggerRealTimeRefresh(
    auth: AuthToken,
    vehicleKey: string | undefined,
  ): Promise<void> {
    try {
      const { text } = await this.loggedFetchRaw(
        `${this.apiURL}rems/rvs`,
        {
          method: 'POST',
          headers: this.authorizedHeaders(auth, vehicleKey),
          body: JSON.stringify({ requestType: 0 }),
        },
        'realTimeRefresh',
      );
      this.checkForKiaErrors(JSON.parse(text) as Record<string, unknown>);
    } catch (err) {
      if (err instanceof APIError && err.errorType === 'invalidCredentials') throw err;
      // swallow — a stale snapshot beats surfacing an error
    }
  }

  // ── Commands ──────────────────────────────────────────────────────────────

  async sendCommand(vehicle: Vehicle, command: VehicleCommand): Promise<void> {
    const auth = await this.ensureAuth();
    const url = this.commandURL(command);
    const body = this.commandBody(command, vehicle);
    const method = this.commandMethod(command);
    const { text } = await this.loggedFetchRaw(url, {
      method,
      headers: this.authorizedHeaders(auth, vehicle.vehicleKey),
      body: method === 'GET' ? undefined : JSON.stringify(body),
    }, 'sendCommand');
    this.checkForKiaErrors(JSON.parse(text) as Record<string, unknown>);
  }

  async fetchEVTripDetails(_vin: string): Promise<EVTripDetail[] | null> {
    return null; // Kia US does not expose EV trip details
  }

  // ── Private Helpers ────────────────────────────────────────────────────────

  private commandMethod(command: VehicleCommand): 'GET' | 'POST' {
    return command.type === 'stopClimate' || command.type === 'stopCharge' ? 'GET' : 'POST';
  }

  private commandURL(command: VehicleCommand): string {
    switch (command.type) {
      case 'lock':         return `${this.apiURL}rems/door/lock`;
      case 'unlock':       return `${this.apiURL}rems/door/unlock`;
      case 'startClimate': return `${this.apiURL}rems/start`;
      case 'stopClimate':  return `${this.apiURL}rems/stop`;
      case 'startCharge':  return `${this.apiURL}evc/charge`;
      case 'stopCharge':   return `${this.apiURL}evc/cancel`;
      case 'setTargetSOC': return `${this.apiURL}evc/sts`;
    }
  }

  private commandBody(
    command: VehicleCommand,
    _vehicle: Vehicle,
  ): Record<string, unknown> {
    if (command.type === 'startClimate') {
      const opts = command.options;
      const seats = {
        driverSeat:    this.seatSetting(opts.frontLeftSeatHeat),
        passengerSeat: this.seatSetting(opts.frontRightSeatHeat),
        rearLeftSeat:  this.seatSetting(0),
        rearRightSeat: this.seatSetting(0),
      };
      const remoteClimate: Record<string, unknown> = {
        airCtrl: opts.heating,
        defrost: opts.defrost,
        airTemp: kiaUSAirTemp(opts.temperature),
        ignitionOnDuration: { unit: 4, value: opts.duration },
        heatingAccessory: { steeringWheel: 0, steeringWheelStep: 0, rearWindow: 0, sideMirror: 0 },
      };
      const hasSeats = Object.values(seats).some(
        (s) => (s as Record<string, number>).heatVentType !== 0,
      );
      if (hasSeats) remoteClimate.heatVentSeat = seats;
      return { remoteClimate };
    }
    if (command.type === 'startCharge') return { chargeRatio: 100 };
    if (command.type === 'setTargetSOC') {
      return {
        targetSOClist: [
          { targetSOClevel: command.dcLevel, plugType: 0 },
          { targetSOClevel: command.acLevel, plugType: 1 },
        ],
      };
    }
    return {};
  }

  private seatSetting(heatLevel: number): Record<string, number> {
    const level = Math.min(Math.max(heatLevel, 0), 3);
    if (level === 0) return { heatVentType: 0, heatVentLevel: 1, heatVentStep: 0 };
    return { heatVentType: 1, heatVentLevel: level + 1, heatVentStep: 4 - level };
  }

  private baseHeaders(): Record<string, string> {
    const offset = -Math.round(new Date().getTimezoneOffset() / 60);
    const host = BASE_URL.replace('https://', '');
    const dateStr = new Date().toUTCString();
    return {
      'content-type': 'application/json;charset=utf-8',
      accept: 'application/json',
      'accept-encoding': 'gzip, deflate, br',
      'accept-language': 'en-US,en;q=0.9',
      'accept-charset': 'utf-8',
      apptype: 'L',
      appversion: '7.22.0',
      clientid: 'SPACL716-APL',
      clientuuid: this.clientUUID,
      from: 'SPA',
      host,
      language: '0',
      offset: String(offset),
      ostype: 'iOS',
      osversion: '15.8.5',
      phonebrand: 'iPhone',
      secretkey: 'sydnat-9kykci-Kuhtep-h5nK',
      to: 'APIGW',
      tokentype: 'A',
      'user-agent': 'KIAPrimo_iOS/37 CFNetwork/1335.0.3.4 Darwin/21.6.0',
      date: dateStr,
      deviceid: this.deviceId,
    };
  }

  private authorizedHeaders(
    auth: AuthToken,
    vehicleKey?: string,
  ): Record<string, string> {
    const headers: Record<string, string> = {
      ...this.baseHeaders(),
      sid: auth.accessToken,
    };
    if (vehicleKey) headers.vinkey = vehicleKey;
    return headers;
  }

  private checkForKiaErrors(json: Record<string, unknown>): void {
    const retCode =
      (json.retCode as string | undefined) ??
      ((json.payload as Record<string, unknown> | undefined)?.retCode as string | undefined);
    if (!retCode || retCode === '0') return;
    const message = (json.message as string | undefined) ?? `Kia error code: ${retCode}`;
    if (retCode === '1') throw new APIError(message, 'invalidCredentials');
    if (retCode === '9001') throw new APIError(message, 'kiaInvalidRequest');
    throw new APIError(message, 'serverError');
  }

  // ── Response Parsing ──────────────────────────────────────────────────────

  private parseVehicleStatus(
    json: Record<string, unknown>,
    vehicle?: Vehicle,
  ): VehicleStatus {
    const payload = (json.payload ?? {}) as Record<string, unknown>;
    const infoList = (payload.vehicleInfoList ?? []) as Record<string, unknown>[];
    const lastVehicleInfo = ((infoList[0] ?? {}).lastVehicleInfo ?? {}) as Record<string, unknown>;
    const statusRpt = (lastVehicleInfo.vehicleStatusRpt ?? {}) as Record<string, unknown>;
    const vs = (statusRpt.vehicleStatus ?? {}) as Record<string, unknown>;

    return {
      lastUpdated: Date.now(),
      syncDate: this.parseSyncDate(vs),
      lockStatus: { locked: (vs.doorLock as boolean | undefined) ?? false },
      climateStatus: this.parseClimateStatus(vs),
      evStatus: this.parseEVStatus(vs),
      gasRange: this.parseGasRange(vs),
      location: this.parseLocation(lastVehicleInfo),
      battery12V: this.parseBattery12V(vs),
      doorOpen: this.parseDoorOpen(vs),
      trunkOpen: this.parseTrunk(vs),
      hoodOpen: this.parseHood(vs),
      odometer: vehicle?.odometer,
    };
  }

  private parseEVStatus(vs: Record<string, unknown>): EVStatus | undefined {
    const ev = (vs.evStatus ?? {}) as Record<string, unknown>;
    const batteryLevel = extractNumber(ev.batteryStatus);
    if (!batteryLevel) return undefined;

    const drvDist = (ev.drvDistance ?? []) as Record<string, unknown>[];
    const rbf = ((drvDist[0] ?? {}).rangeByFuel ?? {}) as Record<string, unknown>;
    const evMode = (rbf.evModeRange ?? {}) as Record<string, unknown>;
    const range: Distance = {
      length: extractNumber(evMode.value) ?? 0,
      units: extractNumber(evMode.unit) === 3 ? 'miles' : 'km',
    };

    const chargeTimes = (ev.remainChargeTime ?? []) as Record<string, unknown>[];
    const chargeMinutes = extractNumber((chargeTimes[0] ?? {}).value) ?? 0;
    const batteryPlugin = extractNumber(ev.batteryPlugin) ?? 0;
    const isCharging = (ev.batteryCharge as boolean | undefined) ?? false;

    const targetSOC = (ev.targetSOC ?? []) as Record<string, unknown>[];
    let acTargetSOC: number | undefined;
    let dcTargetSOC: number | undefined;
    for (const t of targetSOC) {
      const pt = extractNumber(t.plugType);
      const soc = extractNumber(t.targetSOClevel);
      if (pt === 0) dcTargetSOC = soc;
      else if (pt === 1) acTargetSOC = soc;
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

  private parseGasRange(vs: Record<string, unknown>): FuelRange | undefined {
    const fuelLevelRaw = vs.fuelLevel;
    if (fuelLevelRaw == null || isJSONBoolean(fuelLevelRaw)) return undefined;
    const fuelLevel = extractNumber(fuelLevelRaw);
    if (fuelLevel == null) return undefined;
    const dte = (vs.distanceToEmpty ?? {}) as Record<string, unknown>;
    const rangeVal = extractNumber(dte.value);
    const rangeUnit = extractNumber(dte.unit);
    if (rangeVal == null) return undefined;
    return {
      range: { length: rangeVal, units: rangeUnit === 3 ? 'miles' : 'km' },
      fuelLevel,
    };
  }

  private parseClimateStatus(vs: Record<string, unknown>) {
    const climate = (vs.climate ?? {}) as Record<string, unknown>;
    const airTemp = (climate.airTemp ?? {}) as Record<string, unknown>;
    return {
      airControlOn: (climate.airCtrl as boolean | undefined) ?? false,
      defrostOn: (climate.defrost as boolean | undefined) ?? false,
      temperature: airTemp.value != null ? parseFloat(airTemp.value as string) : undefined,
    };
  }

  private parseSyncDate(vs: Record<string, unknown>): number | undefined {
    const sd = (vs.syncDate ?? {}) as Record<string, unknown>;
    const utc = sd.utc as string | undefined;
    if (!utc) return undefined;
    // format: yyyyMMddHHmmss
    const d = new Date(
      `${utc.slice(0, 4)}-${utc.slice(4, 6)}-${utc.slice(6, 8)}T` +
      `${utc.slice(8, 10)}:${utc.slice(10, 12)}:${utc.slice(12, 14)}Z`,
    );
    return isNaN(d.getTime()) ? undefined : d.getTime();
  }

  private parseBattery12V(vs: Record<string, unknown>): number | undefined {
    const bs = vs.batteryStatus as Record<string, unknown> | undefined;
    if (bs) return extractNumber(bs.stateOfCharge);
    const bat = vs.battery as Record<string, unknown> | undefined;
    return bat ? extractNumber(bat.batSoc) : undefined;
  }

  private parseDoorOpen(vs: Record<string, unknown>) {
    const d = ((vs.doorStatus ?? vs.doorOpen) ?? {}) as Record<string, unknown>;
    return {
      frontLeft: (extractNumber(d.frontLeft) ?? 0) !== 0,
      frontRight: (extractNumber(d.frontRight) ?? 0) !== 0,
      rearLeft: (extractNumber(d.rearLeft) ?? 0) !== 0,
      rearRight: (extractNumber(d.rearRight) ?? 0) !== 0,
    };
  }

  private parseTrunk(vs: Record<string, unknown>): boolean | undefined {
    const ds = vs.doorStatus as Record<string, unknown> | undefined;
    if (ds) return (extractNumber(ds.trunk) ?? 0) !== 0;
    return vs.trunkOpen as boolean | undefined;
  }

  private parseHood(vs: Record<string, unknown>): boolean | undefined {
    const ds = vs.doorStatus as Record<string, unknown> | undefined;
    if (ds) return (extractNumber(ds.hood) ?? 0) !== 0;
    return vs.hoodOpen as boolean | undefined;
  }

  private parseLocation(lastVehicleInfo: Record<string, unknown>): VehicleLocation | undefined {
    const loc = (lastVehicleInfo.location ?? {}) as Record<string, unknown>;
    const coord = (loc.coord ?? {}) as Record<string, unknown>;
    const lat = extractNumber(coord.lat);
    const lon = extractNumber(coord.lon);
    if (lat == null || lon == null) return undefined;
    return { latitude: lat, longitude: lon };
  }

  // ── HTTP helper ────────────────────────────────────────────────────────────

  private async loggedFetchRaw(
    url: string,
    init: RequestInit,
    type: string,
  ): Promise<{ text: string; responseHeaders: Record<string, string> }> {
    const start = Date.now();
    const logId = Math.random().toString(36).slice(2);
    const reqHeaders = (init.headers ?? {}) as Record<string, string>;
    try {
      const response = await fetch(url, init);
      const text = await response.text();
      const durationMs = Date.now() - start;
      const responseHeaders: Record<string, string> = {};
      response.headers.forEach((value, key) => { responseHeaders[key] = value; });
      this.config.onHTTPLog?.({
        id: logId, accountId: this.config.accountId, timestamp: start,
        method: (init.method ?? 'GET').toUpperCase(), url,
        requestHeaders: reqHeaders,
        requestBody: init.body != null ? String(init.body) : undefined,
        responseStatus: response.status, responseHeaders, responseBody: text,
        durationMs,
      });
      if (!response.ok) {
        throw new APIError(`HTTP ${response.status}`, 'serverError');
      }
      return { text, responseHeaders };
    } catch (err) {
      if (err instanceof APIError) throw err;
      this.config.onHTTPLog?.({
        id: logId, accountId: this.config.accountId, timestamp: start,
        method: (init.method ?? 'GET').toUpperCase(), url,
        error: String(err), durationMs: Date.now() - start,
      });
      throw new APIError(String(err), 'serverError', err);
    }
  }
}
