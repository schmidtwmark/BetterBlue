import { APIClient, APIClientConfiguration, APIError } from './types';
import { FakeAPIClient } from './FakeAPIClient';
import { HyundaiUSClient } from './HyundaiUSClient';
import { KiaUSClient } from './KiaUSClient';
import { CachedAPIClient } from './CachedAPIClient';

function isTestAccount(username: string): boolean {
  const lower = username.toLowerCase();
  return lower.startsWith('fake@') || lower.startsWith('test@');
}

export function createAPIClient(config: APIClientConfiguration): APIClient {
  if (config.brand === 'fake' || isTestAccount(config.username)) {
    return new FakeAPIClient(config);
  }

  if (config.brand === 'hyundai' && config.region === 'US') {
    return new CachedAPIClient(new HyundaiUSClient(config));
  }

  if (config.brand === 'kia' && config.region === 'US') {
    return new CachedAPIClient(new KiaUSClient(config));
  }

  throw new APIError(
    `Region ${config.region} is not supported for brand ${config.brand}`,
    'regionNotSupported',
  );
}
