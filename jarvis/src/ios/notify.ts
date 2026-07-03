import { dlopen, FFIType } from "bun:ffi";

const LIBNOTIFY = "/usr/lib/system/libsystem_notify.dylib";

const openNotify = () =>
  dlopen(LIBNOTIFY, {
    notify_post: { args: [FFIType.cstring], returns: FFIType.i32 },
  });

let notify: ReturnType<typeof openNotify> | null = null;

export function postDarwinNotification(name: string): void {
  if (process.platform !== "darwin") throw new Error("Darwin notifications are only available on Darwin");
  notify ??= openNotify();
  const rc = notify.symbols.notify_post(Buffer.from(`${name}\0`));
  if (rc !== 0) throw new Error(`notify_post(${name}) failed: ${rc}`);
}
