const AWS = require('aws-sdk');
const apn = require('@parse/node-apn');
const dynamodb = new AWS.DynamoDB.DocumentClient();

const TABLE_NAME = process.env.TABLE_NAME || 'betterblue-wakeup-schedules-v4';

// APNs configuration from environment
const APNS_KEY_ID = process.env.APNS_KEY_ID;
const APNS_TEAM_ID = process.env.APNS_TEAM_ID;
const APNS_KEY = process.env.APNS_KEY;
const APNS_BUNDLE_ID = process.env.APNS_BUNDLE_ID || 'com.markschmidt.BetterBlue';
const APNS_ENVIRONMENT = process.env.APNS_ENVIRONMENT || 'development';

let apnProvider = null;

// Initialize APNs provider (reused across Lambda invocations)
function getAPNsProvider() {
    if (!apnProvider) {
        if (!APNS_KEY || !APNS_KEY_ID || !APNS_TEAM_ID) {
            console.warn('⚠️ APNs credentials not configured');
            return null;
        }

        apnProvider = new apn.Provider({
            token: {
                key: APNS_KEY,
                keyId: APNS_KEY_ID,
                teamId: APNS_TEAM_ID
            },
            production: APNS_ENVIRONMENT === 'production'
        });

        console.log(`✅ APNs provider initialized (${APNS_ENVIRONMENT} mode)`);
    }
    return apnProvider;
}

// Wakeup intervals in minutes by activity type
const WAKEUP_INTERVALS = {
    'debug': 1,      // 1 minute for debug
    'charging': 5,   // 5 minutes for charging
    'default': 5     // Default fallback
};

// API Handler: Register device for wakeup pushes
exports.registerWakeUp = async (event) => {
    try {
        const body = JSON.parse(event.body);
        const { pushToken, activityType } = body;

        if (!pushToken) {
            return {
                statusCode: 400,
                headers: { 'Access-Control-Allow-Origin': '*' },
                body: JSON.stringify({ error: 'Missing pushToken' })
            };
        }

        // Store the push token with activity type for interval-based wakeups
        await dynamodb.put({
            TableName: TABLE_NAME,
            Item: {
                pushToken: pushToken,
                activityType: activityType || 'charging',
                startTime: Date.now(),
                lastPushTime: 0,
                wakeupCount: 0,
                status: 'active'
            }
        }).promise();

        const interval = WAKEUP_INTERVALS[activityType] || WAKEUP_INTERVALS['default'];
        console.log(`✅ Registered device for wakeup pushes: ${pushToken.substring(0, 20)}... (type: ${activityType || 'charging'}, interval: ${interval}min)`);

        return {
            statusCode: 200,
            headers: { 'Access-Control-Allow-Origin': '*' },
            body: JSON.stringify({ success: true })
        };
    } catch (error) {
        console.error('❌ Error in registerWakeUp:', error);
        return {
            statusCode: 500,
            headers: { 'Access-Control-Allow-Origin': '*' },
            body: JSON.stringify({ error: error.message })
        };
    }
};

// API Handler: Unregister wakeup
exports.unregisterWakeUp = async (event) => {
    try {
        const body = JSON.parse(event.body);
        const { pushToken } = body;

        if (!pushToken) {
            return {
                statusCode: 400,
                headers: { 'Access-Control-Allow-Origin': '*' },
                body: JSON.stringify({ error: 'Missing pushToken' })
            };
        }

        await dynamodb.delete({
            TableName: TABLE_NAME,
            Key: { pushToken: pushToken }
        }).promise();

        console.log(`✅ Unregistered device: ${pushToken.substring(0, 20)}...`);

        return {
            statusCode: 200,
            headers: { 'Access-Control-Allow-Origin': '*' },
            body: JSON.stringify({ success: true })
        };
    } catch (error) {
        console.error('❌ Error in unregisterWakeUp:', error);
        return {
            statusCode: 500,
            headers: { 'Access-Control-Allow-Origin': '*' },
            body: JSON.stringify({ error: error.message })
        };
    }
};

// Scheduled Handler: Send background wakeup pushes (runs every minute)
exports.sendWakeUps = async () => {
    try {
        const provider = getAPNsProvider();
        if (!provider) {
            console.error('❌ APNs not configured');
            return { statusCode: 500, body: 'APNs not configured' };
        }

        const now = Date.now();

        // Get all active registrations
        const result = await dynamodb.scan({
            TableName: TABLE_NAME,
            FilterExpression: '#status = :status',
            ExpressionAttributeNames: { '#status': 'status' },
            ExpressionAttributeValues: { ':status': 'active' }
        }).promise();

        console.log(`📋 Found ${result.Items.length} registered devices`);

        const promises = result.Items.map(async (registration) => {
            const tokenShort = registration.pushToken.substring(0, 8);
            const activityType = registration.activityType || 'charging';
            const intervalMinutes = WAKEUP_INTERVALS[activityType] || WAKEUP_INTERVALS['default'];

            try {
                const minutesSinceStart = (now - registration.startTime) / (1000 * 60);
                const minutesSinceLastPush = (now - (registration.lastPushTime || 0)) / (1000 * 60);

                // Auto-expire after 8 hours
                if (minutesSinceStart > 480) {
                    await dynamodb.delete({
                        TableName: TABLE_NAME,
                        Key: { pushToken: registration.pushToken }
                    }).promise();
                    console.log(`⏰ Expired registration ${tokenShort}...`);
                    return;
                }

                // Check if enough time has passed based on activity type interval
                if (registration.lastPushTime && minutesSinceLastPush < intervalMinutes) {
                    // Skip this device - not time yet
                    return;
                }

                // Create a background push notification to wake the app
                const notification = new apn.Notification();
                notification.topic = APNS_BUNDLE_ID;
                notification.pushType = 'background';
                notification.priority = 5; // Must be 5 for background pushes
                notification.expiry = Math.floor(now / 1000) + 60; // 1 min expiry
                notification.contentAvailable = true;
                notification.payload = {
                    liveActivityWakeup: true
                };

                // Send to APNs using the device push token
                const apnsResult = await provider.send(notification, registration.pushToken);

                if (apnsResult.sent.length > 0) {
                    const newCount = (registration.wakeupCount || 0) + 1;
                    await dynamodb.update({
                        TableName: TABLE_NAME,
                        Key: { pushToken: registration.pushToken },
                        UpdateExpression: 'SET lastPushTime = :now, wakeupCount = :count',
                        ExpressionAttributeValues: { ':now': now, ':count': newCount }
                    }).promise();
                    console.log(`✅ ${tokenShort}: wakeup #${newCount} sent (type: ${activityType}, interval: ${intervalMinutes}min, age: ${minutesSinceStart.toFixed(1)}min)`);
                }

                if (apnsResult.failed.length > 0) {
                    const failure = apnsResult.failed[0];
                    console.error(`❌ APNs error for ${tokenShort}: ${failure.status} - ${failure.response?.reason}`);

                    // Remove invalid tokens
                    if (failure.status === '410' ||
                        failure.response?.reason === 'Unregistered' ||
                        failure.response?.reason === 'BadDeviceToken' ||
                        failure.response?.reason === 'ExpiredToken') {
                        await dynamodb.delete({
                            TableName: TABLE_NAME,
                            Key: { pushToken: registration.pushToken }
                        }).promise();
                        console.log(`🗑️ Removed invalid token ${tokenShort}`);
                    }
                }

            } catch (error) {
                console.error(`❌ Error processing ${tokenShort}:`, error);
            }
        });

        await Promise.all(promises);

        return { statusCode: 200, body: `Sent wakeups to ${result.Items.length} devices` };
    } catch (error) {
        console.error('❌ Error in sendWakeUps:', error);
        return { statusCode: 500, body: error.message };
    }
};
