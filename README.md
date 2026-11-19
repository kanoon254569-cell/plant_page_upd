# IRPC_BARCODE_FE_WebBoardman

## Run locally

1. Install the Node.js version supported by the Angular 21 toolchain.
2. Install dependencies:

   ```sh
   npm install
   ```

3. Start the frontend:

   ```sh
   npm start
   ```

4. Open [http://localhost:4200](http://localhost:4200).

## API and sign-in

- Development and production environments use the configured Q Track API. The development API URL is set in `src/environments/environment.development.ts`; use an authorized account and connect to the required network/VPN.
- The Loading List uses the real `GET /api/v1/process/job/loading` endpoint. No demo login or mock API is enabled.

## Build

```sh
npm run build
```