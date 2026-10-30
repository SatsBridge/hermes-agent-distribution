import time

import dbus
import dbus.bus


class SystemdManager:
    def __init__(self):
        self.connection = dbus.bus.BusConnection("unix:path=/run/dbus/system_bus_socket")
        proxy = self.connection.get_object("org.freedesktop.systemd1", "/org/freedesktop/systemd1", introspect=False)
        self.manager = dbus.Interface(proxy, "org.freedesktop.systemd1.Manager")
        self.properties = {}
        self.deadline = time.monotonic() + 2

    def call(self, method, *args):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("systemd validation deadline expired")
        return method(*args, timeout=remaining)

    def unit_info(self, name, with_pid=False):
        if name not in self.properties:
            path = self.call(self.manager.LoadUnit, name)
            proxy = self.connection.get_object("org.freedesktop.systemd1", path, introspect=False)
            self.properties[name] = dbus.Interface(proxy, "org.freedesktop.DBus.Properties")
        properties = self.properties[name]
        values = self.call(properties.GetAll, "org.freedesktop.systemd1.Unit")
        return {
            "Id": str(values["Id"]),
            "ActiveState": str(values["ActiveState"]),
            "InvocationID": bytes(values["InvocationID"]).hex(),
            "MainPID": int(self.call(properties.Get, "org.freedesktop.systemd1.Service", "MainPID"))
            if with_pid else 0,
        }

    def snapshot(self, names, anchor_name, observer_name):
        units = {}
        for unit in self.call(self.manager.ListUnits):
            name = str(unit[0])
            if name in names:
                units[name] = {"Id": name, "ActiveState": str(unit[3]), "path": str(unit[6])}
        for name, fields in ((anchor_name, ("InvocationID", "MainPID")), (observer_name, ("InvocationID",))):
            info = units[name]
            proxy = self.connection.get_object("org.freedesktop.systemd1", info.pop("path"), introspect=False)
            properties = dbus.Interface(proxy, "org.freedesktop.DBus.Properties")
            info["InvocationID"] = bytes(self.call(properties.Get, "org.freedesktop.systemd1.Unit", "InvocationID")).hex()
            if "MainPID" in fields:
                info["MainPID"] = int(self.call(properties.Get, "org.freedesktop.systemd1.Service", "MainPID"))
        return units

    def jobs(self):
        return [(str(job[0]), str(job[1]), str(job[2])) for job in self.call(self.manager.ListJobs)]

    def stop_unit(self, name):
        return self.call(self.manager.StopUnit, name, "replace")
