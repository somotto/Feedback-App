// index.js
const express = require('express');
const { Pool } = require('pg');
const path = require('path');
const jwt = require('jsonwebtoken');
const { S3Client, PutObjectCommand, GetObjectCommand, ListObjectsV2Command } = require('@aws-sdk/client-s3');
const { CloudWatchClient, PutMetricDataCommand } = require('@aws-sdk/client-cloudwatch');
const { SNSClient, PublishCommand } = require('@aws-sdk/client-sns');
const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');

const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public'), { index: false }));

const REGION = process.env.AWS_REGION || 'us-east-1';
const APP_NAME = process.env.APP_NAME || 'web-api';

// AWS clients
const s3 = new S3Client({ region: REGION });
const cw = new CloudWatchClient({ region: REGION });
const sns = new SNSClient({ region: REGION });
const secretsClient = new SecretsManagerClient({ region: REGION });

// RDS connection pool — DB_PASSWORD injected by ECS from Secrets Manager
const pool = new Pool({
  host:     process.env.DB_HOST,
  database: process.env.DB_NAME     || 'appdb',
  user:     process.env.DB_USER     || 'appuser',
  password: process.env.DB_PASSWORD,
  port:     5432,
  ssl: { rejectUnauthorized: false }
});

// ── Helpers ──────────────────────────────────────────────────────────────────

// Fetch jwt_secret from Secrets Manager (cached after first call)
let _jwtSecret = null;
async function getJwtSecret() {
  if (_jwtSecret) return _jwtSecret;
  try {
    const res = await secretsClient.send(new GetSecretValueCommand({
      SecretId: `${APP_NAME}/app`
    }));
    _jwtSecret = JSON.parse(res.SecretString).jwt_secret;
  } catch {
    _jwtSecret = process.env.JWT_SECRET || 'local-dev-secret';
  }
  return _jwtSecret;
}

// Push a custom metric to CloudWatch
async function putMetric(metricName, value, unit = 'Count') {
  try {
    await cw.send(new PutMetricDataCommand({
      Namespace: `${APP_NAME}/App`,
      MetricData: [{
        MetricName: metricName,
        Value: value,
        Unit: unit,
        Dimensions: [{ Name: 'Environment', Value: process.env.ENV || 'dev' }]
      }]
    }));
  } catch (err) {
    console.error('CloudWatch metric error:', err.message);
  }
}

// Publish an SNS notification
async function notify(subject, message) {
  if (!process.env.SNS_TOPIC_ARN) return;
  try {
    await sns.send(new PublishCommand({
      TopicArn: process.env.SNS_TOPIC_ARN,
      Subject: subject,
      Message: message
    }));
  } catch (err) {
    console.error('SNS publish error:', err.message);
  }
}

// Ensure ratings table exists on startup
async function initDB() {
  try {
    await pool.query(`
      CREATE TABLE IF NOT EXISTS ratings (
        id         SERIAL PRIMARY KEY,
        rating     INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
        created_at TIMESTAMPTZ DEFAULT NOW()
      )
    `);
    console.log('DB ready');
  } catch (err) {
    console.error('DB init error:', err.message);
  }
}

// ── Routes ───────────────────────────────────────────────────────────────────

// Health check — no DB, used by ALB target group
app.get('/healthz', (req, res) => res.json({ status: 'healthy', timestamp: new Date() }));

// DB connectivity test
app.get('/db-check', async (req, res) => {
  try {
    const result = await pool.query('SELECT NOW()');
    res.json({ connected: true, time: result.rows[0].now });
  } catch (err) {
    res.status(500).json({ connected: false, error: err.message });
  }
});

// Submit a rating → persists to RDS, pushes metric to CloudWatch, archives to S3
app.post('/rating', async (req, res) => {
  const { rating } = req.body;
  if (!rating || rating < 1 || rating > 5) {
    return res.status(400).json({ error: 'Rating must be between 1 and 5' });
  }

  try {
    // 1. Persist to RDS
    const result = await pool.query(
      'INSERT INTO ratings (rating) VALUES ($1) RETURNING *',
      [rating]
    );
    const row = result.rows[0];

    // 2. Custom CloudWatch metric — track rating submissions
    await putMetric('RatingSubmitted', 1);
    await putMetric('RatingValue', rating, 'None');

    // 3. Archive rating as JSON to S3
    if (process.env.S3_BUCKET) {
      await s3.send(new PutObjectCommand({
        Bucket: process.env.S3_BUCKET,
        Key: `ratings/${row.id}.json`,
        Body: JSON.stringify(row),
        ContentType: 'application/json'
      }));
    }

    res.json({ success: true, data: row });
  } catch (err) {
    // Notify via SNS on errors
    await notify('Rating submission error', err.message);
    res.status(500).json({ error: err.message });
  }
});

// Get all ratings from RDS + summary stats
app.get('/ratings', async (req, res) => {
  try {
    const { rows } = await pool.query(
      'SELECT rating, COUNT(*) AS count FROM ratings GROUP BY rating ORDER BY rating'
    );
    const total = rows.reduce((sum, r) => sum + parseInt(r.count), 0);
    const avg   = total
      ? rows.reduce((sum, r) => sum + r.rating * parseInt(r.count), 0) / total
      : 0;

    res.json({ summary: { total, average: +avg.toFixed(2) }, breakdown: rows });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// List archived ratings from S3
app.get('/ratings/archive', async (req, res) => {
  if (!process.env.S3_BUCKET) {
    return res.status(503).json({ error: 'S3_BUCKET not configured' });
  }
  try {
    const list = await s3.send(new ListObjectsV2Command({
      Bucket: process.env.S3_BUCKET,
      Prefix: 'ratings/'
    }));
    res.json({
      bucket: process.env.S3_BUCKET,
      count: list.KeyCount,
      files: (list.Contents || []).map(o => ({ key: o.Key, size: o.Size, lastModified: o.LastModified }))
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Issue a JWT signed with the secret from Secrets Manager
app.post('/token', async (req, res) => {
  const { user } = req.body;
  if (!user) return res.status(400).json({ error: 'user is required' });
  const secret = await getJwtSecret();
  const token  = jwt.sign({ user }, secret, { expiresIn: '1h' });
  res.json({ token });
});

// Verify a JWT
app.post('/token/verify', async (req, res) => {
  const { token } = req.body;
  if (!token) return res.status(400).json({ error: 'token is required' });
  try {
    const secret  = await getJwtSecret();
    const decoded = jwt.verify(token, secret);
    res.json({ valid: true, decoded });
  } catch (err) {
    res.status(401).json({ valid: false, error: err.message });
  }
});

// Serve the feedback card UI
app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// ── Start ─────────────────────────────────────────────────────────────────────
initDB().then(() => {
  app.listen(3000, '0.0.0.0', () => console.log('Server listening on port 3000'));
});
