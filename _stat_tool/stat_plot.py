import json
import matplotlib.pyplot as plt

events_key = "events"
frame_count_key = "frame_count"
records_key = "records"

restir_keys: list[str] = [
    # 1
    "/onFrameRender/RenderGraphExe::execute()/RestirInitTemporal/cpu_time",
    # 2
    "/onFrameRender/RenderGraphExe::execute()/RestirInitTemporal/gpu_time",
    # 3
    "/onFrameRender/RenderGraphExe::execute()"  # New line
    "/RestirInitTemporal/raytraceScene/cpu_time",
    # 4
    "/onFrameRender/RenderGraphExe::execute()"  # New line
    "/RestirInitTemporal/raytraceScene/gpu_time"
]


def create_plot(x_axes: list[list], y_axes: list[list], labels: list[str],
                colors: list[str], title: str):

    if len(x_axes) != len(y_axes) \
            or len(x_axes) != len(labels) \
            or len(x_axes) != len(colors):
        print("Not equal num of entries")
        return

    (fig, ax) = plt.subplots(1, 1)
    ax.set_title(title)
    ax.grid(True)

    num = len(x_axes)
    for i in range(num):
        x_axis = x_axes[i]
        y_axis = y_axes[i]
        label = labels[i]
        color = colors[i]
        ax.plot(x_axis, y_axis, color=color,
                label=label, linestyle="-", marker=" ")

    ax.legend()

    plt.show()

    return (fig, ax)


def main():
    with open("./test_profile.json") as file:
        data = json.load(file)

    frame_count = data[frame_count_key]
    events = data[events_key]

    records_1 = events[restir_keys[0]][records_key]

    x_frame_num = [i + 1 for i in range(frame_count)]

    create_plot([x_frame_num], [records_1], ["ReSTIR"], ['b'], "CPU Time")



if __name__ == "__main__":
    main()
