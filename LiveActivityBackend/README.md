# BetterBlue Live Activity Backend

A lightweight serverless backend that enables Live Activity updates for the BetterBlue iOS app. This service sends periodic silent push notifications to wake the app and refresh charging status on the Lock Screen and Dynamic Island.

## Privacy

**No private information about your vehicle or account ever leaves your device.**

This backend only stores:
- Your device's APNs push token (an anonymous identifier assigned by Apple)
- The type of activity (e.g., "charging")
- A timestamp for expiration purposes

The backend does **not** receive or store:
- Vehicle information (VIN, location, battery level, etc.)
- Account credentials (username, password, PIN)
- Any personal information

All vehicle data fetching happens directly on your device after receiving a silent wake-up push.

## How It Works

```
┌─────────────────┐     1. Register      ┌─────────────────┐
│   BetterBlue    │ ──────────────────▶  │    Backend      │
│   iOS App       │     (push token)     │   (Lambda)      │
└─────────────────┘                      └─────────────────┘
        │                                        │
        │                                        │ 2. Every 5 min
        │                                        │    (scheduled)
        │                                        ▼
        │                                ┌─────────────────┐
        │   3. Silent push               │     APNs        │
        │◀─────────────────────────────  │  (Apple Push)   │
        │                                └─────────────────┘
        │
        │ 4. App wakes, fetches
        │    status from Hyundai/Kia
        ▼
┌─────────────────┐
│  Live Activity  │
│    Updated!     │
└─────────────────┘
```

1. When a Live Activity starts, the app registers its push token with this backend
2. A scheduled Lambda function runs every minute and checks for active registrations
3. For each registration, it sends a silent background push via APNs
4. The app wakes up, fetches fresh vehicle status directly from Hyundai/Kia servers, and updates the Live Activity
5. Registrations automatically expire after 8 hours

## Architecture

Built with the [Serverless Framework](https://www.serverless.com/) on AWS:

- **API Gateway** - REST endpoints for registration
- **Lambda** - Serverless functions for handling requests
- **DynamoDB** - Stores push token registrations
- **EventBridge** - Triggers the scheduled wake-up function
- **APNs** - Apple Push Notification service for silent pushes

## API Endpoints

### POST /wakeup
Register a device for wake-up pushes.

```json
{
  "pushToken": "device-apns-token",
  "activityType": "charging"
}
```

### POST /wakeup/unregister
Unregister a device (called when Live Activity ends).

```json
{
  "pushToken": "device-apns-token"
}
```

## Deployment

### Prerequisites
- Node.js 18+
- AWS CLI configured with credentials
- Serverless Framework CLI (`npm install -g serverless`)
- APNs key stored in AWS SSM Parameter Store at `/betterblue/apns-key`

### Deploy

```bash
# Install dependencies
npm install

# Deploy to development
npx serverless deploy --stage dev

# Deploy to production
npx serverless deploy --stage prod
```

### Environment Variables

| Variable | Description |
|----------|-------------|
| `APNS_KEY_ID` | Apple Push Notification key ID |
| `APNS_TEAM_ID` | Apple Developer Team ID |
| `APNS_BUNDLE_ID` | App bundle identifier |
| `APNS_KEY` | APNs private key (via SSM) |

## Wake-up Intervals

Different activity types have different refresh intervals:

| Activity Type | Interval |
|--------------|----------|
| `charging` | 5 minutes |
| `debug` | 1 minute |

## Cost

This backend is designed to be extremely low-cost:

- Lambda: Falls within free tier for typical usage
- DynamoDB: Pay-per-request, minimal with sparse registrations
- API Gateway: Minimal requests (only on activity start/end)
- CloudWatch Logs: 3-7 day retention to minimize storage costs

## License

This project is part of [BetterBlue](https://github.com/schmidtwmark/BetterBlue) and is open source.
