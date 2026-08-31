using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FlashSale.OrderService.Migrations
{
    /// <inheritdoc />
    public partial class AddOutboxEvents : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "outbox_events",
                schema: "order_service",
                columns: table => new
                {
                    Id = table.Column<Guid>(type: "uuid", nullable: false),
                    OrderId = table.Column<Guid>(type: "uuid", nullable: false),
                    EventType = table.Column<string>(type: "text", nullable: false),
                    Payload = table.Column<string>(type: "jsonb", nullable: false),
                    Published = table.Column<bool>(type: "boolean", nullable: false),
                    CreatedAt = table.Column<DateTime>(type: "timestamp without time zone", nullable: false),
                    PublishedAt = table.Column<DateTime>(type: "timestamp without time zone", nullable: true)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_outbox_events", x => x.Id);
                });

            migrationBuilder.CreateIndex(
                name: "IX_outbox_events_Published",
                schema: "order_service",
                table: "outbox_events",
                column: "Published");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "outbox_events",
                schema: "order_service");
        }
    }
}
