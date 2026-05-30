/**
 * Fake API Client for testing and development.
 *
 * Returns deterministic fake vehicle data without making real API calls.
 * Activate by using a username that starts with `fake@` or `test@`.
 */
import type {
  APIClient,
  AuthToken,
  APIClientConfiguration,
  ClimateStatus,
  EVTripDetail,
  FuelType,
  LockStatus,
  MFAMethod,
  Vehicle,
  VehicleCommand,
  VehicleStatus,
} from './types';
import { APIError } from './types';

const FAKE_VEHICLES: Omit<Vehicle, 'accountId'>[] = [
  {
    id: 'FAKE_VIN_EV_001',
    vin: 'FAKE_VIN_EV_001',
    regId: 'FAKE_REG_EV_001',
    model: 'Ioniq 6',
    fuelType: 'electric',
    generation: 2,
    isHidden: false,
    sortOrder: 0,
    backgroundColorName: 'default',
    chargePortType: 'CCS1',
    enableSeatHeatControls: true,
    vehicleKey: 'FAKE_VK_EV_001',
  },
  {
    id: 'FAKE_VIN_GAS_001',
    vin: 'FAKE_VIN_GAS_001',
    regId: 'FAKE_REG_GAS_001',
    model: 'Tucson',
    fuelType: 'gas',
    generation: 2,
    isHidden: false,
    sortOrder: 1,
    backgroundColorName: 'default',
    chargePortType: 'CCS1',
    enableSeatHeatControls: false,
  },
];

interface FakeVehicleState {
  locked: boolean;
  climateOn: boolean;
  temperature: number;
  batteryLevel: number;
  isCharging: boolean;
}

const defaultState = (): FakeVehicleState => ({
  locked: true,
  climateOn: false,
  temperature: 70,
  batteryLevel: 80,
  isCharging: false,
});

export class FakeAPIClient implements APIClient {
  private readonly config: APIClientConfiguration;
  private readonly state = new Map<string, FakeVehicleState>();

  constructor(config: APIClientConfiguration) {
    this.config = config;
  }

  async initialize(): Promise<void> {
    // No-op
  }

  supportsMFA(): boolean {
    return false;
  }

  private fakeToken(): AuthToken {
    return {
      accessToken: 'fake_access_token',
      expiresAt: Date.now() + 3600 * 1000,
    };
  }

  private getState(vin: string): FakeVehicleState {
    if (!this.state.has(vin)) this.state.set(vin, defaultState());
    return this.state.get(vin)!;
  }

  async fetchVehicles(): Promise<Vehicle[]> {
    await this.delay(300);
    return FAKE_VEHICLES.map((v) => ({ ...v, accountId: this.config.accountId }));
  }

  async fetchVehicleStatus(
    vin: string,
    _regId: string,
    _vehicleKey?: string,
    _cached?: boolean,
  ): Promise<VehicleStatus> {
    await this.delay(600);
    const s = this.getState(vin);
    const isEV = FAKE_VEHICLES.find((v) => v.vin === vin)?.fuelType === 'electric';

    const lockStatus: LockStatus = { locked: s.locked };
    const climateStatus: ClimateStatus = {
      airControlOn: s.climateOn,
      temperature: s.temperature,
      defrostOn: false,
    };

    return {
      lastUpdated: Date.now(),
      lockStatus,
      climateStatus,
      location: { latitude: 47.6062, longitude: -122.3321 },
      battery12V: 95,
      doorOpen: { frontLeft: false, frontRight: false, rearLeft: false, rearRight: false },
      trunkOpen: false,
      hoodOpen: false,
      ...(isEV
        ? {
            evStatus: {
              batteryLevel: s.batteryLevel,
              range: { length: Math.round((s.batteryLevel / 100) * 266), units: 'miles' },
              chargeStatus: s.isCharging ? 'charging' : 'not_charging',
              isCharging: s.isCharging,
              isPluggedIn: s.isCharging,
              chargeRemainingMinutes: s.isCharging ? 45 : 0,
              acTargetSOC: 80,
              dcTargetSOC: 80,
            },
          }
        : {
            gasRange: {
              range: { length: 320, units: 'miles' },
              fuelLevel: 75,
            },
          }),
    };
  }

  async sendCommand(vehicle: Vehicle, command: VehicleCommand): Promise<void> {
    await this.delay(1500);
    const s = this.getState(vehicle.vin);
    switch (command.type) {
      case 'lock':         s.locked = true; break;
      case 'unlock':       s.locked = false; break;
      case 'startClimate': s.climateOn = true; s.temperature = command.options.temperature; break;
      case 'stopClimate':  s.climateOn = false; break;
      case 'startCharge':  s.isCharging = true; break;
      case 'stopCharge':   s.isCharging = false; break;
      case 'setTargetSOC': /* no-op for fake */ break;
    }
  }

  async fetchEVTripDetails(_vin: string): Promise<EVTripDetail[] | null> {
    return [
      { tripId: 'fake-trip-1', date: Date.now() - 86400000, distance: { length: 24.5, units: 'miles' }, energyUsed: 6.2 },
      { tripId: 'fake-trip-2', date: Date.now() - 172800000, distance: { length: 18.3, units: 'miles' }, energyUsed: 4.7 },
    ];
  }

  async sendMFACode(_xid: string, _otpKey: string, _method: MFAMethod): Promise<void> {
    throw new APIError('MFA not supported by FakeAPIClient', 'general');
  }

  async verifyMFACode(
    _xid: string,
    _otpKey: string,
    _code: string,
  ): Promise<{ rememberMeToken: string; sid: string }> {
    throw new APIError('MFA not supported by FakeAPIClient', 'general');
  }

  async completeMFALogin(_sid: string, _rmToken: string): Promise<void> {
    throw new APIError('MFA not supported by FakeAPIClient', 'general');
  }

  private delay(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}
