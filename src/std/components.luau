--ReplicatedStorage/std/components.luau

local jecs = require(game:GetService("ReplicatedStorage").ecs)
local world = require(script.Parent.world)

type Entity<T = nil> = jecs.Entity<T>
local components: {
	Character: Entity<Model>,
	Model: Entity<Model>,
	Player: Entity,
	Target: Entity,
	Transform: Entity<{ new: CFrame, old: CFrame }>,
	Velocity: Entity<number>,
	Previous: Entity,
	Size: Entity<number>,

	PendingChunks: Entity<{ [number]:{cx:number, cz:number, blocks: Vector3} }>,

} = {
		Character = world:component(),
		Mob = world:component(),
		Model = world:component(),
		Player = world:component(),
		Target = world:component(),
		Transform = world:component(),
		Velocity = world:component(),
		Previous = world:component(),
		Size = world:component(),

		PendingChunks = world:component()
}

for name, component in components :: {[string]: jecs.Entity} do 
	world:set(component, jecs.Name, name)
end

return table.freeze(components)
