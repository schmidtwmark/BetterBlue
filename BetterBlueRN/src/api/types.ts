export type Brand = 'hyundai' | 'kia' | 'fake';
export type Region = 'US' | 'CA' | 'EU' | 'AU' | 'KR';
export type FuelType = 'gas' | 'electric' | 'phev';
export type DistanceUnit = 'miles' | 'km';
export type TemperatureUnit = 'celsius' | 'fahrenheit';
export type ChargePortType = 'CCS1' | 'CCS2' | 'NACS';
export type SeatHeatLevel = 0 | 1 | 2 | 3;
export type MFAMethod = 'sms' | 'email';
export type BackgroundColorName =
  | 'default'
  | 'charcoal'
  | 'midnight'
  | 'forest'
  | 'ocean'
  | 'crimson';

export interface Account {
  id: string;
  username: string;
  brand: Brand;
  region: Region;
  deviceId?: string;
  rememberMeToken?: string;
  refreshToken?: string;
  serializedAuthToken?: string;
  lastVehiclesFetch?: number;
}

export interface AuthToken {
  accessToken: string;
  refreshToken?: string;
  expiresAt: number;
  tokenType?: string;
}

export interface Vehicle {
  id: string;
  vin: string;
  regId: string;
  model: string;
  accountId: string;
  fuelType: FuelType;
  fuelTypeOverride?: FuelType;
  generation: number;
  vehicleKey?: string;
  customName?: string;
  isHidden: boolean;
  sortOrder: number;
  backgroundColorName: BackgroundColorName;
  chargePortType: ChargePortType;
  enableSeatHeatControls: boolean;
  showClimateDurationOverride?: boolean;
  primaryColorName?: string;
  chargingColorName?: string;
  gasColorName?: string;
  lockColorName?: string;
  unlockColorName?: string;
  startClimateColorName?: string;
  stopColorName?: string;
  lastUpdated?: number;
  syncDate?: number;
  gasRange?: FuelRange;
  evStatus?: EVStatus;
  location?: VehicleLocation;
  lockStatus?: LockStatus;
  climateStatus?: ClimateStatus;
  battery12V?: number;
  doorOpen?: DoorStatus;
  trunkOpen?: boolean;
  hoodOpen?: boolean;
  tirePressureWarning?: boolean;
  odometer?: Distance;
}

export interface Distance {
  length: number;
  units: DistanceUnit;
}

export interface FuelRange {
  range: Distance;
  fuelLevel: number;
}

export interface EVStatus {
  batteryLevel: number;
  range: Distance;
  chargeStatus: 'charging' | 'not_charging' | 'unknown';
  plugType?: 'unplugged' | 'ac' | 'dc';
  chargeRemainingMinutes?: number;
  dcTargetSOC?: number;
  acTargetSOC?: number;
  isCharging: boolean;
  isPluggedIn: boolean;
}

export interface VehicleLocation {
  latitude: number;
  longitude: number;
  altitude?: number;
  timestamp?: number;
}

export interface LockStatus {
  locked: boolean;
}

export interface ClimateStatus {
  airControlOn: boolean;
  temperature?: number;
  defrostOn?: boolean;
  seatHeatLeft?: SeatHeatLevel;
  seatHeatRight?: SeatHeatLevel;
}

export interface DoorStatus {
  frontLeft?: boolean;
  frontRight?: boolean;
  rearLeft?: boolean;
  rearRight?: boolean;
}

export interface VehicleStatus {
  lastUpdated: number;
  syncDate?: number;
  gasRange?: FuelRange;
  evStatus?: EVStatus;
  location?: VehicleLocation;
  lockStatus?: LockStatus;
  climateStatus?: ClimateStatus;
  battery12V?: number;
  doorOpen?: DoorStatus;
  trunkOpen?: boolean;
  hoodOpen?: boolean;
  tirePressureWarning?: boolean;
  odometer?: Distance;
}

export type VehicleCommand =
  | { type: 'lock' }
  | { type: 'unlock' }
  | { type: 'startClimate'; options: ClimateOptions }
  | { type: 'stopClimate' }
  | { type: 'startCharge' }
  | { type: 'stopCharge' }
  | { type: 'setTargetSOC'; acLevel: number; dcLevel: number };

export interface ClimateOptions {
  /** Temperature in Celsius; clients convert to Fahrenheit as required by their API. */
  temperature: number;
  defrost: boolean;
  heating: boolean;
  frontLeftSeatHeat: SeatHeatLevel;
  frontRightSeatHeat: SeatHeatLevel;
  duration: number;
}

export interface ClimatePreset {
  id: string;
  vehicleId: string;
  name: string;
  iconName: string;
  isSelected: boolean;
  sortOrder: number;
  temperature: number;
  temperatureUnit: TemperatureUnit;
  defrost: boolean;
  frontLeftSeatHeat: SeatHeatLevel;
  frontRightSeatHeat: SeatHeatLevel;
  duration: number;
}

export interface APIClientConfiguration {
  brand: Brand;
  region: Region;
  username: string;
  password: string;
  pin: string;
  accountId: string;
  deviceId?: string;
  rememberMeToken?: string;
  refreshToken?: string;
  onRememberMeTokenRotated?: (token: string) => void;
  onHTTPLog?: (log: HTTPLogEntry) => void;
}

export interface HTTPLogEntry {
  id: string;
  accountId: string;
  timestamp: number;
  method: string;
  url: string;
  requestHeaders?: Record<string, string>;
  requestBody?: string;
  responseStatus?: number;
  responseHeaders?: Record<string, string>;
  responseBody?: string;
  error?: string;
  durationMs: number;
}

export interface MFAInfo {
  xid: string;
  otpKey: string;
  email?: string;
  phone?: string;
  notifyType?: string;
}

export class APIError extends Error {
  constructor(
    message: string,
    public readonly errorType: APIErrorType,
    public readonly originalError?: unknown,
    public readonly mfaInfo?: MFAInfo,
  ) {
    super(message);
    this.name = 'APIError';
  }
}

export type APIErrorType =
  | 'invalidCredentials'
  | 'invalidPin'
  | 'invalidVehicleSession'
  | 'requiresMFA'
  | 'failedRetryLogin'
  | 'serverError'
  | 'concurrentRequest'
  | 'regionNotSupported'
  | 'kiaInvalidRequest'
  | 'general';

export interface AppSettings {
  distanceUnit: DistanceUnit;
  temperatureUnit: TemperatureUnit;
  notificationsEnabled: boolean;
  debugModeEnabled: boolean;
}

export interface EVTripDetail {
  tripId: string;
  date: number;
  distance: Distance;
  energyUsed: number;
}

export interface APIClient {
  initialize(): Promise<void>;
  fetchVehicles(): Promise<Vehicle[]>;
  fetchVehicleStatus(
    vin: string,
    regId: string,
    vehicleKey?: string,
    cached?: boolean,
  ): Promise<VehicleStatus>;
  sendCommand(vehicle: Vehicle, command: VehicleCommand): Promise<void>;
  fetchEVTripDetails?(vin: string): Promise<EVTripDetail[] | null>;
  supportsMFA(): boolean;
  sendMFACode(xid: string, otpKey: string, method: MFAMethod): Promise<void>;
  verifyMFACode(
    xid: string,
    otpKey: string,
    code: string,
  ): Promise<{ rememberMeToken: string; sid: string }>;
  completeMFALogin(sid: string, rmToken: string): Promise<void>;
}
