To calculate the power consumption of LPDDR under "continuous access", we cannot give an absolute number, because it is extremely dependent on **specific generations of LPDDR (such as LPDDR4X vs LPDDR5)**, **transmission rate (MT/s)** and **memory capacity (GB)**.

However, we can estimate it from the common unit power consumption benchmark (mW/GB) in the industry.

### 1. Estimate logic

Dynamic power consumption of memory mainly depends on the frequency and access activity of data transmission. In the case of continuous access, we can refer to the average power consumption performance of the LPDDR generation:

* **LPDDR4X:** Under continuous access operation, the power consumption is about **150 mW / GB**.
* **LPDDR5:** Under continuous access operation, the power consumption is about **120 mW / GB**.

*(Note: The above value is the common operating power consumption per GB, and the actual value will fluctuate depending on the process and time pulse.) *

### 2. Example of power consumption calculation

Assume that you are using a module with **4GB capacity** (assuming that this is the total amount of memory configured in the system), and take **10 seconds** as the operating cycle:

#### Situation A: Use LPDDR4X (150 mW/GB)

* **Single-second power consumption:** $4 \text{ GB} \times 150 \text{ mW/GB} = 600 \text{ mW} = 0.6 \text{ W}$
* **Total power consumption in 10 seconds:** $0.6 \text{ W} \times 10 \text{ seconds} = \mathbf{6 \text{ Joules (Joules)}}$

#### Situation B: Use LPDDR5 (120 mW/GB)

* **Single-second power consumption:** $4 \text{ GB} \times 120 \text{ mW/GB} = 480 \text{ mW} = 0.48 \text{ W}$
* **Total power consumption in 10 seconds:** $0.48 \text{ W} \times 10 \text{ seconds} = \mathbf{4.8 \text{ Joules (Joules)}}$

---

### three. Key factors affecting accuracy

The above is a rough estimate. If you need more accurate values, you must consider the following variables:

1. **Data width and frequency:** The amount of data accessed to 400MB is fixed, but if you read it in a very short time with a very high frequency, the transition loss (Transition Overhead) of the hardware entering the low-power state will be different.
2. ** Access type: ** The power consumption of "Read" is different from that of "Write". Write operations usually consume more power than reading.
3. **SoC controller power consumption:** The above value usually refers to the memory chip itself. In fact, when accessing memory, the memory controller and PHY layer inside SoC will also consume a lot of power (about 20%-40% of the overall memory subsystem power consumption).

### Suggestions

If you are designing system-level power consumption, it is recommended to use the **"System Power Calculator"** tool provided by various original DRAM factories (such as Micron, Samsung, SK Hynix). These spreadsheets input the correct frequency, voltage and access mode (Activity Factor), which can provide data closer to the real scene than manual calculation.
