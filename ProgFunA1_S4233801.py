# Programming Fundamentals (COSC2531)
# Assignment 1
# Soham Chaitanya Athawale 
# S4233801
# -----------------------------------------
# Task 1 
# Initial Data

customers = ["Tim", "Rose"]
members = ["Tim"]

services = {
    "inspection": {"hours": 1.0, "needs_hours": False, "needs_part": False},
    "diagnostic": {"hours": 1.0, "needs_hours": False, "needs_part": False},
    "maintenance": {"hours": 2.0, "needs_hours": False, "needs_part": True},
    "repair": {"hours": 0.0, "needs_hours": True, "needs_part": True}
}

parts = {
    "oil": 35.0,
    "filter": 25.0,
    "brake": 120.0,
    "battery": 180.0,
    "radiator": 420.0,
    "motor": 280.0
}

SERVICE_COST_PER_HOUR = 40.0

# Input 

# Get customer name
customer_name = input("Enter customer name: ")

# Add new customer if not already in list
if customer_name not in customers:
    customers.append(customer_name)

# Get service requested (with error handling)
while True:
    service_name = input("Enter the service requested: ")
    if service_name in services:
        break
    else:
        print("Invalid service. Please try again.")

service = services[service_name]

# Get service hours if required
if service["needs_hours"]:
    hours = float(input("Enter number of service hours: "))
else:
    hours = service["hours"]

# Get part if required
part_name = None
part_cost = 0.0

if service["needs_part"]:
    while True:
        part_name = input("Enter part name: ")
        if part_name in parts:
            part_cost = parts[part_name]
            break
        else:
            print("Invalid part. Please try again.")


# Calculation

service_cost = hours * SERVICE_COST_PER_HOUR
original_cost = service_cost + part_cost


# Membership and Discount

discount = 0.0

# Apply discount only if already a member
if customer_name in members:
    discount = 0.10 * original_cost
else:
    # Offer membership 
    choice = input("Would you like to become a member? (yes/no): ")
    if choice.lower() == "yes":
        members.append(customer_name)

# Final cost after giving discount
final_cost = original_cost - discount

# Receipt

print("---------------------------------------------------------------------------")
print("Receipt")
print("---------------------------------------------------------------------------")

print(f"{service_name}: {hours:.2f} x {SERVICE_COST_PER_HOUR:.2f}")

if part_name:
    print(f"{part_name}: {part_cost:.2f}")

print("---------------------------------------------------------------------------")
print(f"Original cost: {original_cost:.2f} (AUD)")
print(f"Discount: {discount:.2f} (AUD)")
print(f"Total cost: {final_cost:.2f} (AUD)")