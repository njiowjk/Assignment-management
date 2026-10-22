import { BackendError, safeError } from "./errors.js";
import { mergeTasks } from "./merge.js";
import { parseICS } from "./connectors/ics-parser.js";
import { MoodleConnector } from "./connectors/moodle.js";
import { WebClassConnector } from "./connectors/webclass.js";
import { checkCompletions } from "./connectors/moodle-completion.js";
import { decodeSession } from "./connectors/moodle-session.js";
import { calendarURL, localTasks, record, remoteTasks, source, text, timestamp } from "./validation.js";

const MAX_MESSAGE_BYTES = 32 * 1024 * 1024;

async function execute(value: unknown): Promise<unknown> {
  const request = record(value);
  if (request.version !== 1) throw new BackendError("backend");
  switch (request.command) {
    case "fetchMoodle": {
      const url = text(request.calendarURL);
      const tasks = await new MoodleConnector(url, text(request.timeZone)).fetchTasks();
      if (request.session == null) return tasks;
      return checkCompletions(tasks, localTasks(request.existing ?? []), decodeSession(request.session, calendarURL(url)));
    }
    case "fetchWebClass": return new WebClassConnector().fetchTasks();
    case "parseICS":
      return parseICS(Buffer.from(text(request.calendarBase64), "base64"), text(request.timeZone));
    case "merge":
      return mergeTasks(localTasks(request.existing), remoteTasks(request.tasks), source(request.source), timestamp(request.now));
    case "health": return { protocolVersion: 1 };
    default: throw new BackendError("backend");
  }
}

// One request per process; stdout is exclusively the protocol. Never log request data or caught errors.
try {
  const chunks: Buffer[] = [];
  let length = 0;
  for await (const chunk of process.stdin) {
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    length += bytes.length;
    if (length > MAX_MESSAGE_BYTES) throw new BackendError("tooLarge");
    chunks.push(bytes);
  }
  const result = await execute(JSON.parse(Buffer.concat(chunks).toString("utf8")) as unknown);
  const response = JSON.stringify({ version: 1, ok: true, result });
  if (Buffer.byteLength(response) > MAX_MESSAGE_BYTES) throw new BackendError("tooLarge");
  process.stdout.write(response + "\n");
} catch (error) {
  process.stdout.write(JSON.stringify({ version: 1, ok: false, error: { code: safeError(error) } }) + "\n");
}
